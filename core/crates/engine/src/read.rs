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

    /// What was on screen for a frame.
    pub fn frame_context(&self, frame_id: i64) -> Result<Option<remind_store::FrameContext>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        Ok(reader
            .prepare_cached(
                "SELECT s.bundle_id, s.window, s.url, s.profile FROM frame f
                 JOIN segment s ON s.id = f.segment_id WHERE f.id = ?1",
            )?
            .query_row(params![frame_id], |r| {
                Ok(remind_store::FrameContext {
                    bundle_id: r.get(0)?,
                    window: r.get(1)?,
                    url: r.get(2)?,
                    profile: r.get(3)?,
                    front_rect: None,
                })
            })
            .optional()?)
    }

    /// The next frame after this one on the same display, moving forward or back.
    pub fn neighbour(&self, frame_id: i64, forward: bool) -> Result<Option<FrameRef>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        let sql = if forward {
            "SELECT n.id, n.t_ms FROM frame f JOIN frame n ON n.display_id = f.display_id
             WHERE f.id = ?1 AND (n.t_ms, n.id) > (f.t_ms, f.id)
             ORDER BY n.t_ms, n.id LIMIT 1"
        } else {
            "SELECT n.id, n.t_ms FROM frame f JOIN frame n ON n.display_id = f.display_id
             WHERE f.id = ?1 AND (n.t_ms, n.id) < (f.t_ms, f.id)
             ORDER BY n.t_ms DESC, n.id DESC LIMIT 1"
        };
        Ok(reader
            .prepare_cached(sql)?
            .query_row(params![frame_id], |r| Ok(FrameRef { id: r.get(0)?, t_ms: r.get(1)? }))
            .optional()?)
    }

    /// Runs for part of the timeline, simplified for drawing.
    pub fn timeline(
        &self,
        display_uuid: &[u8; 16],
        from_ms: i64,
        to_ms: i64,
        min_duration_ms: i64,
    ) -> Result<remind_timeline::Timeline> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        Ok(remind_timeline::load(&reader, display_uuid, from_ms, to_ms, min_duration_ms)?)
    }

    /// Every app that has been recorded, most recent first, for filtering searches.
    pub fn recorded_apps(&self) -> Result<Vec<String>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        let mut statement = reader.prepare_cached(
            "SELECT bundle_id FROM segment WHERE bundle_id IS NOT NULL
             GROUP BY bundle_id ORDER BY max(t_end) DESC",
        )?;
        let apps = statement.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        Ok(apps)
    }

    /// Stars or unstars a frame.
    pub fn set_starred(&self, frame_id: i64, starred: bool) -> Result<()> {
        let (reply, response) = crossbeam_channel::bounded(1);
        self.writes
            .as_ref()
            .ok_or(EngineError::Stopped)?
            .send(crate::writer::WriterMessage::SetStarred(frame_id, starred, reply))
            .map_err(|_| EngineError::Stopped)?;
        response.recv().map_err(|_| EngineError::Stopped)?
    }

    /// Which of the given periods have any recording.
    pub fn active_periods(&self, periods: &[(i64, i64)]) -> Result<Vec<bool>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        Ok(remind_timeline::active_periods(&reader, periods)?)
    }

    /// Reads only the keyframe of a frame's group, for scrubbing too fast to decode
    /// everything.
    pub fn read_keyframe(&self, frame_id: i64) -> Result<Gop> {
        let (path, rows, target_frame) = {
            let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
            let (path, chunk_id, seq): (String, i64, i64) = reader
                .prepare_cached(
                    "SELECT c.path, f.chunk_id, f.seq FROM frame f
                     JOIN chunk c ON c.id = f.chunk_id WHERE f.id = ?1",
                )?
                .query_row(params![frame_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .optional()?
                .ok_or(EngineError::NoSuchFrame)?;
            let row: (i64, i64, i64, i64, u32, bool) = reader
                .prepare_cached(
                    "SELECT id, t_ms, seq, offset, len, is_sync FROM frame
                     WHERE chunk_id = ?1 AND seq <= ?2 AND is_sync = 1 ORDER BY seq DESC LIMIT 1",
                )?
                .query_row(params![chunk_id, seq], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?))
                })
                .optional()?
                .ok_or_else(|| EngineError::Corrupt(format!("frame {frame_id} has no keyframe")))?;
            (path, vec![row], frame_id)
        };
        let _ = target_frame;
        let (reader, samples) = read_range(&self.root, &self.master, &path, &rows)?;
        let header = reader.header();
        Ok(Gop {
            width: header.width,
            height: header.height,
            parameter_sets: header.parameter_sets.clone(),
            samples,
            target: 0,
        })
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
