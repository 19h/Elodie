//! Reads frames back for display and verification.

use remind_vault::{ChunkReader, MasterKey};
use rusqlite::{OptionalExtension, params};

use crate::appender::path_in;
use crate::{Engine, EngineError, Result};

/// A frame's identity and when it was captured.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FrameRef {
    pub id: i64,
    pub t_ms: i64,
}

/// One sample in a group of pictures.
#[derive(Clone, Debug)]
pub struct GopSample {
    pub frame_id: i64,
    pub t_ms: i64,
    pub mono_ns: u64,
    pub is_sync: bool,
    pub data: Vec<u8>,
}

/// A keyframe and the samples that depend on it, enough to decode any of them.
#[derive(Clone, Debug)]
pub struct Gop {
    pub width: u32,
    pub height: u32,
    pub parameter_sets: Vec<u8>,
    pub samples: Vec<GopSample>,
    /// The index in `samples` of the frame that was asked for.
    pub target: usize,
}

fn read_range(
    root: &std::path::Path,
    master: &MasterKey,
    path: &str,
    rows: &[(i64, i64, i64, i64, u32, bool)],
) -> Result<(ChunkReader, Vec<GopSample>)> {
    let reader = ChunkReader::open(&path_in(root, path), master)?;
    let mut samples = Vec::with_capacity(rows.len());
    for &(frame_id, t_ms, seq, offset, len, is_sync) in rows {
        let record = reader.read_at(seq as u64, offset as u64, len)?;
        samples.push(GopSample {
            frame_id,
            t_ms,
            mono_ns: record.mono_ns,
            is_sync,
            data: record.sample,
        });
    }
    Ok((reader, samples))
}

impl Engine {
    /// The latest frame at or before `t_ms` on a display.
    pub fn lookup(&self, display_uuid: &[u8; 16], t_ms: i64) -> Result<Option<FrameRef>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        Ok(reader
            .prepare_cached(
                "SELECT f.id, f.t_ms FROM frame f
                 WHERE f.display_id = (SELECT id FROM display WHERE uuid = ?1) AND f.t_ms <= ?2
                 ORDER BY f.t_ms DESC LIMIT 1",
            )?
            .query_row(params![display_uuid.as_slice(), t_ms], |r| {
                Ok(FrameRef { id: r.get(0)?, t_ms: r.get(1)? })
            })
            .optional()?)
    }

    /// Reads the group of pictures containing a frame.
    pub fn read_gop(&self, frame_id: i64) -> Result<Gop> {
        let (path, rows, target) = {
            let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
            let (path, chunk_id, seq): (String, i64, i64) = reader
                .prepare_cached(
                    "SELECT c.path, f.chunk_id, f.seq FROM frame f
                     JOIN chunk c ON c.id = f.chunk_id WHERE f.id = ?1",
                )?
                .query_row(params![frame_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .optional()?
                .ok_or(EngineError::NoSuchFrame)?;

            let start: i64 = reader
                .prepare_cached(
                    "SELECT max(seq) FROM frame WHERE chunk_id = ?1 AND seq <= ?2 AND is_sync = 1",
                )?
                .query_row(params![chunk_id, seq], |r| r.get::<_, Option<i64>>(0))?
                .ok_or_else(|| EngineError::Corrupt(format!("frame {frame_id} has no keyframe")))?;
            let end: i64 = reader
                .prepare_cached(
                    "SELECT coalesce(min(seq), 9223372036854775807) FROM frame
                     WHERE chunk_id = ?1 AND seq > ?2 AND is_sync = 1",
                )?
                .query_row(params![chunk_id, seq], |r| r.get(0))?;

            let rows: Vec<(i64, i64, i64, i64, u32, bool)> = reader
                .prepare_cached(
                    "SELECT id, t_ms, seq, offset, len, is_sync FROM frame
                     WHERE chunk_id = ?1 AND seq >= ?2 AND seq < ?3 ORDER BY seq",
                )?
                .query_map(params![chunk_id, start, end], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?))
                })?
                .collect::<rusqlite::Result<_>>()?;
            (path, rows, (seq - start) as usize)
        };

        // The database lock isn't held while reading and decrypting.
        let (reader, samples) = read_range(&self.root, &self.master, &path, &rows)?;
        let header = reader.header();
        Ok(Gop {
            width: header.width,
            height: header.height,
            parameter_sets: header.parameter_sets.clone(),
            samples,
            target,
        })
    }

    /// A new read connection, for tools and tests.
    pub fn open_reader(&self) -> Result<rusqlite::Connection> {
        Ok(remind_store::open_reader(
            &self.root.join("vault.db"),
            &remind_store::DbKey(self.db_key),
        )?)
    }
}
