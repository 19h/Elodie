//! Brings the database and the log back into agreement after a crash.
//!
//! A kill leaves the log ahead of the database, so missing records are replayed.
//! A power cut can leave the database ahead of the log, because the log is only
//! flushed every few seconds, so rows past the log's valid end are deleted.
//!
//! Every chunk not marked sealed gets checked. Scanning decrypts every record,
//! and unsealed chunks are few and small, so this stays fast.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use rayon::prelude::*;
use elodie_store::{ChunkInfo, LoggedFrame, project, segment};
use elodie_vault::{ChunkReader, MasterKey, ScanStart, VaultError, flags, recover_tail};
use rusqlite::{Connection, Transaction, params};

use crate::Result;
use crate::appender::path_in;

/// What recovery found and did.
#[derive(Clone, Debug, Default)]
pub struct RecoveryReport {
    pub chunks_checked: u64,
    pub frames_replayed: u64,
    /// Database rows removed because the log no longer has them.
    pub frames_removed: u64,
    /// Chunks whose torn tails were trimmed.
    pub chunks_trimmed: u64,
    /// Chunks removed because they contained no records.
    pub chunks_removed: u64,
    /// Chunks that couldn't be read and were left in place for inspection.
    pub chunks_unreadable: u64,
    pub duration: Duration,
}

/// One chunk's state, from scanning it.
struct ScannedChunk {
    uuid: [u8; 16],
    relative: String,
    valid_len: u64,
    record_count: u64,
    torn: bool,
    file_len: u64,
    first_t: i64,
    frames: Vec<LoggedFrame>,
}

enum ScanOutcome {
    Chunk(ScannedChunk),
    /// The file was cut off before its header was complete, so it never held a
    /// record.
    Headerless(PathBuf),
    /// The header didn't authenticate. Never delete in this case: it might be a
    /// wrong key rather than a damaged file.
    Unreadable,
}

fn relative_path(root: &Path, path: &Path) -> Option<String> {
    Some(path.strip_prefix(root).ok()?.to_str()?.to_owned())
}

fn scan_chunk(root: &Path, master: &MasterKey, path: &Path) -> ScanOutcome {
    let reader = match ChunkReader::open(path, master) {
        Ok(reader) => reader,
        Err(VaultError::NotAChunk | VaultError::Malformed) => {
            return ScanOutcome::Headerless(path.to_owned());
        }
        Err(_) => return ScanOutcome::Unreadable,
    };
    let Some(relative) = relative_path(root, path) else {
        return ScanOutcome::Unreadable;
    };
    let header = reader.header().clone();
    let info = ChunkInfo {
        uuid: header.id,
        display_uuid: header.display_uuid,
        width: header.width,
        height: header.height,
        path: relative.clone(),
    };

    let mut scan = reader.scan(ScanStart::Beginning);
    let mut frames = Vec::new();
    for found in scan.by_ref() {
        frames.push(LoggedFrame {
            chunk: info.clone(),
            seq: found.location.seq,
            offset: found.location.offset,
            len: found.location.len,
            t_ms: found.record.wall_ms,
            is_sync: found.record.flags & flags::SYNC != 0,
            context: segment::decode_context(&found.record.meta).unwrap_or_default(),
        });
    }
    let (valid_len, record_count, torn) = (scan.valid_len(), scan.next_seq(), scan.is_torn());
    let file_len = std::fs::metadata(path).map(|m| m.len()).unwrap_or(valid_len);
    let first_t = frames.first().map_or(i64::MAX, |f| f.t_ms);

    ScanOutcome::Chunk(ScannedChunk {
        uuid: header.id,
        relative,
        valid_len,
        record_count,
        torn,
        file_len,
        first_t,
        frames,
    })
}

fn all_chunk_files(root: &Path) -> std::io::Result<Vec<PathBuf>> {
    let chunks = root.join("chunks");
    let mut files = Vec::new();
    let Ok(shards) = std::fs::read_dir(&chunks) else {
        return Ok(files);
    };
    for shard in shards {
        // Looking through this folder in Finder leaves a .DS_Store here.
        let entries = match std::fs::read_dir(shard?.path()) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotADirectory => continue,
            Err(error) => return Err(error),
        };
        for entry in entries {
            let path = entry?.path();
            if path.extension().is_some_and(|e| e == "chunk") {
                files.push(path);
            }
        }
    }
    Ok(files)
}

fn sealed_chunks(conn: &Connection) -> rusqlite::Result<HashSet<String>> {
    let mut stmt = conn.prepare("SELECT path FROM chunk WHERE sealed = 1")?;
    stmt.query_map([], |r| r.get(0))?.collect()
}

fn unsealed_chunks(conn: &Connection) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare("SELECT path FROM chunk WHERE sealed = 0")?;
    stmt.query_map([], |r| r.get(0))?.collect()
}

/// After frames are removed, shrinks the segments they were in, and removes any
/// left with no frames.
fn prune_segments(tx: &Transaction<'_>, segment_ids: &[i64]) -> rusqlite::Result<()> {
    for &segment_id in segment_ids {
        let remaining: Option<i64> = tx.query_row(
            "SELECT max(t_ms) FROM frame WHERE segment_id = ?1",
            params![segment_id],
            |r| r.get(0),
        )?;
        match remaining {
            Some(t_end) => {
                tx.execute("UPDATE segment SET t_end = ?2 WHERE id = ?1", params![segment_id, t_end])?;
            }
            None => {
                tx.execute("DELETE FROM segment WHERE id = ?1", params![segment_id])?;
            }
        }
    }
    Ok(())
}

/// Removes a chunk's rows. Returns how many frames were removed.
fn forget_chunk(conn: &mut Connection, relative: &str) -> rusqlite::Result<u64> {
    let tx = conn.transaction()?;
    let segments: Vec<i64> = {
        let mut stmt = tx.prepare(
            "SELECT DISTINCT f.segment_id FROM frame f JOIN chunk c ON c.id = f.chunk_id
             WHERE c.path = ?1 AND f.segment_id IS NOT NULL",
        )?;
        stmt.query_map(params![relative], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?
    };
    let frames = tx.execute(
        "DELETE FROM frame WHERE chunk_id = (SELECT id FROM chunk WHERE path = ?1)",
        params![relative],
    )?;
    tx.execute("DELETE FROM chunk WHERE path = ?1", params![relative])?;
    prune_segments(&tx, &segments)?;
    tx.commit()?;
    Ok(frames as u64)
}

/// Brings the database into line with the log. Must run before any writes.
pub(crate) fn recover(
    root: &Path,
    master: &MasterKey,
    conn: &mut Connection,
) -> Result<RecoveryReport> {
    let started = Instant::now();
    let mut report = RecoveryReport::default();

    // Finish any deletion a crash interrupted. This has to come first, or a chunk
    // waiting to be removed would look like one to replay, and deleted frames would
    // come back.
    crate::delete::recover(root, conn)?;

    let sealed = sealed_chunks(conn)?;
    let to_check: Vec<PathBuf> = all_chunk_files(root)?
        .into_iter()
        .filter(|path| relative_path(root, path).is_none_or(|r| !sealed.contains(&r)))
        .collect();
    report.chunks_checked = to_check.len() as u64;

    // Decrypting is the costly part, so it runs across all chunks in parallel.
    let outcomes: Vec<ScanOutcome> =
        to_check.par_iter().map(|path| scan_chunk(root, master, path)).collect();

    let mut chunks = Vec::new();
    for outcome in outcomes {
        match outcome {
            ScanOutcome::Chunk(chunk) => chunks.push(chunk),
            ScanOutcome::Headerless(path) => {
                // Forget the rows first, so a crash here can't leave rows
                // pointing at a file that's gone.
                if let Some(relative) = relative_path(root, &path) {
                    report.frames_removed += forget_chunk(conn, &relative)?;
                }
                std::fs::remove_file(&path)?;
                report.chunks_removed += 1;
            }
            ScanOutcome::Unreadable => report.chunks_unreadable += 1,
        }
    }

    // Unsealed rows whose file has vanished have nothing left to read.
    let missing: Vec<String> = unsealed_chunks(conn)?
        .into_iter()
        .filter(|relative| !path_in(root, relative).exists())
        .collect();
    for relative in &missing {
        report.frames_removed += forget_chunk(conn, relative)?;
        report.chunks_removed += 1;
    }

    // Segments depend on arrival order, so replay chunks oldest first.
    chunks.sort_by_key(|chunk| chunk.first_t);

    for chunk in &chunks {
        reconcile_chunk(root, conn, chunk, &mut report)?;
    }

    report.duration = started.elapsed();
    Ok(report)
}

fn reconcile_chunk(
    root: &Path,
    conn: &mut Connection,
    chunk: &ScannedChunk,
    report: &mut RecoveryReport,
) -> Result<()> {
    let path = path_in(root, &chunk.relative);
    let tx = conn.transaction()?;

    // Forget anything past the end of the valid log.
    let affected: Vec<i64> = {
        let mut stmt = tx.prepare(
            "SELECT DISTINCT f.segment_id FROM frame f JOIN chunk c ON c.id = f.chunk_id
             WHERE c.uuid = ?1 AND f.seq >= ?2 AND f.segment_id IS NOT NULL",
        )?;
        stmt.query_map(params![chunk.uuid.as_slice(), chunk.record_count as i64], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?
    };
    let removed = tx.execute(
        "DELETE FROM frame WHERE seq >= ?2
           AND chunk_id = (SELECT id FROM chunk WHERE uuid = ?1)",
        params![chunk.uuid.as_slice(), chunk.record_count as i64],
    )?;
    report.frames_removed += removed as u64;

    prune_segments(&tx, &affected)?;

    // A chunk with no records holds nothing worth keeping.
    if chunk.record_count == 0 {
        tx.execute("DELETE FROM chunk WHERE uuid = ?1", params![chunk.uuid.as_slice()])?;
        tx.commit()?;
        std::fs::remove_file(&path)?;
        report.chunks_removed += 1;
        return Ok(());
    }

    // Roll the bookkeeping back if the database claimed more than the log has.
    tx.execute(
        "UPDATE chunk SET indexed_seq = min(indexed_seq, ?2) WHERE uuid = ?1",
        params![chunk.uuid.as_slice(), chunk.record_count as i64 - 1],
    )?;

    for frame in &chunk.frames {
        let before: i64 = tx
            .query_row(
                "SELECT indexed_seq FROM chunk WHERE uuid = ?1",
                params![chunk.uuid.as_slice()],
                |r| r.get(0),
            )
            .unwrap_or(-1);
        project::apply_one(&tx, frame)?;
        if (frame.seq as i64) > before {
            report.frames_replayed += 1;
        }
    }

    tx.execute(
        "UPDATE chunk SET
             sealed = 1,
             t_min = (SELECT min(t_ms) FROM frame WHERE chunk_id = chunk.id),
             t_max = (SELECT max(t_ms) FROM frame WHERE chunk_id = chunk.id)
         WHERE uuid = ?1",
        params![chunk.uuid.as_slice()],
    )?;
    tx.commit()?;

    // Trim only after the database no longer refers to the tail.
    if chunk.torn || chunk.file_len > chunk.valid_len {
        recover_tail(&path, chunk.valid_len)?;
        report.chunks_trimmed += 1;
    }
    Ok(())
}
