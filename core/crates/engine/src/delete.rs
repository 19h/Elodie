//! Deletes recordings, so that the data is really gone rather than hidden.
//!
//! Whole chunks are removed. A chunk that's only partly affected gets rewritten with
//! just the frames that remain. Text is handled the same way: a run keeps only the
//! lines its remaining frames show, so deleted words leave the index too.
//!
//! P-frames depend on the frames before them. Frames after a deleted stretch can't be
//! decoded until the next keyframe, so those go too. That's at most one group of
//! pictures. Re-encoding them would save them, but needs the encoder, which lives in
//! Swift.
//!
//! # Crash safety
//!
//! Rewritten chunks are written outside `chunks/`, so a crash can't make recovery
//! mistake one for new recordings. The database then commits, in one transaction, the
//! new frame locations and a `purge` row for the old file. Files move only after that
//! commit, and recovery finishes whatever's left. The old data can't return, because
//! `purge` is handled before recovery looks for chunks to replay.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use remind_store::text::ocr_state;
use remind_text::{RunLine, codec};
use remind_vault::{ChunkHeader, ChunkReader, ChunkWriter, MasterKey, RecordRef};
use rusqlite::{Connection, OptionalExtension, Transaction, params};

use crate::appender::{chunk_relative_path, path_in};
use crate::writer::WriterMessage;
use crate::{Engine, EngineError, Result};

const REWRITE_DIRECTORY: &str = "rewrite";

/// What the writer thread needs in order to delete a range.
pub(crate) struct DeleteRequest {
    from_ms: i64,
    to_ms: i64,
    root: PathBuf,
    master: MasterKey,
}

/// What was done, and which files to change once it has committed.
pub(crate) struct Outcome {
    pub(crate) frames_removed: u64,
    pub(crate) files_to_remove: Vec<PathBuf>,
    pub(crate) files_to_move: Vec<(PathBuf, PathBuf)>,
}

fn io_failure(error: impl std::fmt::Display) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(std::io::Error::other(error.to_string())))
}

struct ChunkRow {
    id: i64,
    path: String,
    display_id: i64,
}

struct FrameRow {
    id: i64,
    t_ms: i64,
    seq: i64,
    offset: i64,
    len: u32,
    is_sync: bool,
}

/// Applies a deletion inside a transaction.
pub(crate) fn apply(tx: &Transaction<'_>, request: &DeleteRequest) -> rusqlite::Result<Outcome> {
    let (from, to) = (request.from_ms, request.to_ms);
    let mut outcome =
        Outcome { frames_removed: 0, files_to_remove: Vec::new(), files_to_move: Vec::new() };

    let chunks: Vec<ChunkRow> = {
        let mut statement = tx.prepare(
            "SELECT id, path, display_id FROM chunk WHERE t_max >= ?1 AND t_min <= ?2",
        )?;
        statement
            .query_map(params![from, to], |r| {
                Ok(ChunkRow { id: r.get(0)?, path: r.get(1)?, display_id: r.get(2)? })
            })?
            .collect::<rusqlite::Result<_>>()?
    };

    let segments: HashSet<i64> = {
        let mut statement = tx.prepare(
            "SELECT DISTINCT segment_id FROM frame
             WHERE t_ms >= ?1 AND t_ms <= ?2 AND segment_id IS NOT NULL",
        )?;
        statement.query_map(params![from, to], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?
    };
    let runs: HashSet<i64> = {
        let mut statement = tx.prepare(
            "SELECT DISTINCT run_id FROM frame
             WHERE t_ms >= ?1 AND t_ms <= ?2 AND run_id IS NOT NULL",
        )?;
        statement.query_map(params![from, to], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?
    };

    let mut affected_runs = runs;
    let mut affected_segments = segments;

    for chunk in &chunks {
        let frames: Vec<FrameRow> = {
            let mut statement = tx.prepare(
                "SELECT id, t_ms, seq, offset, len, is_sync FROM frame
                 WHERE chunk_id = ?1 ORDER BY seq",
            )?;
            statement
                .query_map(params![chunk.id], |r| {
                    Ok(FrameRow {
                        id: r.get(0)?,
                        t_ms: r.get(1)?,
                        seq: r.get(2)?,
                        offset: r.get(3)?,
                        len: r.get(4)?,
                        is_sync: r.get(5)?,
                    })
                })?
                .collect::<rusqlite::Result<_>>()?
        };

        // Which survive: everything outside the range, except P-frames that lost
        // their chain because something before them went.
        let mut chain_broken = false;
        let survivors: Vec<&FrameRow> = frames
            .iter()
            .filter(|frame| {
                if frame.t_ms >= from && frame.t_ms <= to {
                    chain_broken = true;
                    return false;
                }
                if frame.is_sync {
                    chain_broken = false;
                }
                !chain_broken
            })
            .collect();
        let survivor_ids: HashSet<i64> = survivors.iter().map(|frame| frame.id).collect();

        // Dropped frames can belong to runs and segments past the range itself.
        for frame in frames.iter().filter(|f| !survivor_ids.contains(&f.id)) {
            let (run, segment): (Option<i64>, Option<i64>) = tx.query_row(
                "SELECT run_id, segment_id FROM frame WHERE id = ?1",
                params![frame.id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?;
            affected_runs.extend(run);
            affected_segments.extend(segment);
            tx.execute("DELETE FROM frame WHERE id = ?1", params![frame.id])?;
            outcome.frames_removed += 1;
        }

        let old_path = path_in(&request.root, &chunk.path);
        if survivors.is_empty() {
            tx.execute("DELETE FROM chunk WHERE id = ?1", params![chunk.id])?;
            tx.execute("INSERT OR IGNORE INTO purge(path) VALUES (?1)", params![chunk.path])?;
            outcome.files_to_remove.push(old_path);
        } else if survivors.len() < frames.len() {
            rewrite_chunk(tx, request, chunk, &survivors, &old_path, &mut outcome)?;
        }
    }

    prune_runs(tx, &affected_runs)?;
    prune_segments(tx, &affected_segments)?;
    Ok(outcome)
}

/// Writes a new chunk holding only `survivors`, and points their rows at it.
fn rewrite_chunk(
    tx: &Transaction<'_>,
    request: &DeleteRequest,
    chunk: &ChunkRow,
    survivors: &[&FrameRow],
    old_path: &Path,
    outcome: &mut Outcome,
) -> rusqlite::Result<()> {
    let reader = ChunkReader::open(old_path, &request.master).map_err(io_failure)?;
    let old = reader.header().clone();

    let mut id = [0u8; 16];
    getrandom::fill(&mut id).map_err(io_failure)?;
    let relative = chunk_relative_path(&id);
    let final_path = path_in(&request.root, &relative);
    let hex: String = id.iter().map(|b| format!("{b:02x}")).collect();
    let temporary = request.root.join(REWRITE_DIRECTORY).join(format!("{hex}.chunk"));

    let mut writer = ChunkWriter::create(
        &temporary,
        &request.master,
        ChunkHeader {
            id,
            display_uuid: old.display_uuid,
            width: old.width,
            height: old.height,
            parameter_sets: old.parameter_sets.clone(),
        },
    )
    .map_err(io_failure)?;

    let mut placements = Vec::with_capacity(survivors.len());
    for frame in survivors {
        let record = reader
            .read_at(frame.seq as u64, frame.offset as u64, frame.len)
            .map_err(io_failure)?;
        let placed = writer
            .append(RecordRef {
                wall_ms: record.wall_ms,
                mono_ns: record.mono_ns,
                flags: record.flags,
                meta: &record.meta,
                sample: &record.sample,
            })
            .map_err(io_failure)?;
        placements.push((frame.id, frame.t_ms, placed));
    }
    let end = writer.len();
    writer.seal().map_err(io_failure)?;

    tx.execute(
        "INSERT INTO chunk(uuid, display_id, width, height, t_min, t_max, path, indexed_seq, indexed_offset, sealed)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 1)",
        params![
            id.as_slice(),
            chunk.display_id,
            old.width,
            old.height,
            placements.iter().map(|p| p.1).min(),
            placements.iter().map(|p| p.1).max(),
            relative,
            placements.len() as i64 - 1,
            end as i64
        ],
    )?;
    let new_chunk = tx.last_insert_rowid();
    for (frame_id, _, placed) in &placements {
        tx.execute(
            "UPDATE frame SET chunk_id = ?2, seq = ?3, offset = ?4, len = ?5 WHERE id = ?1",
            params![frame_id, new_chunk, placed.seq as i64, placed.offset as i64, placed.len],
        )?;
    }
    tx.execute("DELETE FROM chunk WHERE id = ?1", params![chunk.id])?;
    tx.execute("INSERT OR IGNORE INTO purge(path) VALUES (?1)", params![chunk.path])?;

    outcome.files_to_move.push((temporary, final_path));
    outcome.files_to_remove.push(old_path.to_owned());
    Ok(())
}

/// Removes runs with no frames left. A run that lost some frames keeps only the lines
/// its remaining frames show, so deleted text can't be found or read.
fn prune_runs(tx: &Transaction<'_>, runs: &HashSet<i64>) -> rusqlite::Result<()> {
    for &run in runs {
        let frames: Vec<(i64, Vec<u8>)> = {
            let mut statement =
                tx.prepare_cached("SELECT frame_id, lines_z FROM frame_text WHERE run_id = ?1")?;
            statement
                .query_map(params![run], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<rusqlite::Result<_>>()?
        };
        if frames.is_empty() {
            tx.execute("DELETE FROM run_fts WHERE rowid = ?1", params![run])?;
            tx.execute("DELETE FROM text_run WHERE id = ?1", params![run])?;
            continue;
        }

        let Some((lines_z, title)): Option<(Vec<u8>, String)> = tx
            .query_row(
                "SELECT r.lines_z, coalesce(s.window, '') FROM text_run r
                 LEFT JOIN segment s ON s.id = r.segment_id WHERE r.id = ?1",
                params![run],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?
        else {
            continue;
        };
        let lines = codec::decode_lines(&lines_z).map_err(io_failure)?;
        let decoded: Vec<(i64, Vec<(u32, remind_text::Rect)>)> = frames
            .iter()
            .map(|(id, compressed)| Ok((*id, codec::decode_frame_lines(compressed)?)))
            .collect::<std::io::Result<_>>()
            .map_err(io_failure)?;

        let used: HashSet<u32> =
            decoded.iter().flat_map(|(_, shown)| shown.iter().map(|(number, _)| *number)).collect();
        let (t_first, t_last): (i64, i64) = tx.query_row(
            "SELECT min(t_ms), max(t_ms) FROM frame WHERE run_id = ?1",
            params![run],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        tx.execute(
            "UPDATE text_run SET t_first = ?2, t_last = ?3 WHERE id = ?1",
            params![run, t_first, t_last],
        )?;
        if used.len() == lines.len() {
            continue;
        }

        // Renumber the lines that are left, and rewrite everything that refers to them.
        let mut renumber: HashMap<u32, u32> = HashMap::with_capacity(used.len());
        let mut kept: Vec<RunLine> = Vec::with_capacity(used.len());
        for (number, line) in lines.into_iter().enumerate() {
            if used.contains(&(number as u32)) {
                renumber.insert(number as u32, kept.len() as u32);
                kept.push(line);
            }
        }
        for (frame_id, shown) in decoded {
            let remapped: Vec<_> =
                shown.into_iter().map(|(number, rect)| (renumber[&number], rect)).collect();
            let compressed = codec::encode_frame_lines(&remapped).map_err(io_failure)?;
            tx.execute(
                "UPDATE frame_text SET lines_z = ?2 WHERE frame_id = ?1",
                params![frame_id, compressed],
            )?;
        }
        let compressed = codec::encode_lines(&kept).map_err(io_failure)?;
        tx.execute("UPDATE text_run SET lines_z = ?2 WHERE id = ?1", params![run, compressed])?;

        let mut front = String::new();
        let mut other = String::new();
        for line in &kept {
            let column = if line.is_front { &mut front } else { &mut other };
            if !column.is_empty() {
                column.push(remind_text::LINE_SEPARATOR);
            }
            column.push_str(&line.text);
        }
        tx.execute(
            "INSERT OR REPLACE INTO run_fts(rowid, text, other, title) VALUES (?1, ?2, ?3, ?4)",
            params![run, front, other, title],
        )?;
    }
    Ok(())
}

fn prune_segments(tx: &Transaction<'_>, segments: &HashSet<i64>) -> rusqlite::Result<()> {
    for &segment in segments {
        let range: (Option<i64>, Option<i64>) = tx.query_row(
            "SELECT min(t_ms), max(t_ms) FROM frame WHERE segment_id = ?1",
            params![segment],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        match range {
            (Some(start), Some(end)) => {
                tx.execute(
                    "UPDATE segment SET t_start = ?2, t_end = ?3 WHERE id = ?1",
                    params![segment, start, end],
                )?;
            }
            _ => {
                tx.execute("DELETE FROM segment WHERE id = ?1", params![segment])?;
            }
        }
    }
    Ok(())
}

/// Finishes the file changes after the transaction commits. A failure here is safe,
/// because recovery finishes the job on the next launch.
pub(crate) fn finish(conn: &Connection, moves: &[(PathBuf, PathBuf)], removals: &[PathBuf]) {
    for (from, to) in moves {
        if let Some(parent) = to.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::rename(from, to);
    }
    let mut all_removed = true;
    for path in removals {
        match std::fs::remove_file(path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => all_removed = false,
        }
    }
    if all_removed {
        let _ = conn.execute("DELETE FROM purge", []);
    }
}

/// Finishes a deletion that a crash interrupted.
pub(crate) fn recover(root: &Path, conn: &mut Connection) -> Result<()> {
    // Old chunks go first, so they can't be mistaken for recordings to replay.
    let paths: Vec<String> = {
        let mut statement = conn.prepare("SELECT path FROM purge")?;
        statement.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?
    };
    for relative in &paths {
        match std::fs::remove_file(path_in(root, relative)) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    conn.execute("DELETE FROM purge", [])?;

    // A rewritten chunk counts only if its transaction committed.
    let directory = root.join(REWRITE_DIRECTORY);
    let Ok(entries) = std::fs::read_dir(&directory) else {
        return Ok(());
    };
    for entry in entries {
        let path = entry?.path();
        let Some(hex) = path.file_stem().and_then(|stem| stem.to_str()) else { continue };
        let id: Vec<u8> = (0..hex.len() / 2)
            .filter_map(|i| u8::from_str_radix(hex.get(i * 2..i * 2 + 2)?, 16).ok())
            .collect();
        let known: Option<String> = conn
            .query_row("SELECT path FROM chunk WHERE uuid = ?1", params![id], |r| r.get(0))
            .optional()?;
        match known {
            Some(relative) => {
                let target = path_in(root, &relative);
                if let Some(parent) = target.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                std::fs::rename(&path, &target)?;
            }
            None => std::fs::remove_file(&path)?,
        }
    }
    Ok(())
}

impl Engine {
    /// Permanently deletes frames captured from `from_ms` through `to_ms`, along with
    /// their text. Returns how many frames were removed. A few frames after the range
    /// also go, up to the next keyframe, because they can't be decoded without what
    /// came before.
    pub fn delete_range(&self, from_ms: i64, to_ms: i64) -> Result<u64> {
        // Open chunks can't be rewritten, so everything gets sealed first. New frames
        // then start a new chunk, which this doesn't touch.
        self.seal_all()?;
        let (reply, response) = crossbeam_channel::bounded(1);
        self.writes
            .as_ref()
            .ok_or(EngineError::Stopped)?
            .send(WriterMessage::DeleteRange(
                DeleteRequest {
                    from_ms,
                    to_ms,
                    root: self.root.clone(),
                    master: self.master.clone(),
                },
                reply,
            ))
            .map_err(|_| EngineError::Stopped)?;
        response.recv().map_err(|_| EngineError::Stopped)?
    }

    /// How many frames are still waiting for OCR. For monitoring.
    pub fn ocr_backlog(&self) -> Result<i64> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        Ok(reader.query_row(
            "SELECT count(*) FROM frame WHERE ocr_state IN (?1, ?2)",
            params![ocr_state::PENDING, ocr_state::DEFERRED],
            |r| r.get(0),
        )?)
    }
}
