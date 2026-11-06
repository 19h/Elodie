//! Reads frames back for display and verification.

use elodie_vault::{ChunkReader, MasterKey};
use rusqlite::{OptionalExtension, params};

use crate::appender::path_in;
use crate::{Engine, EngineError, Result};

/// A line of text in a frame, and where it is.
#[derive(Clone, Debug, PartialEq)]
pub struct FrameTextLine {
    pub text: String,
    pub rect: elodie_text::Rect,
}

/// A meeting that was transcribed.
#[derive(Clone, Debug, PartialEq)]
pub struct Meeting {
    pub title: Option<String>,
    pub t_start: i64,
    pub t_end: Option<i64>,
}

/// A display that has recordings.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecordedDisplay {
    pub uuid: [u8; 16],
    pub width: i64,
    pub height: i64,
    pub first_ms: i64,
    pub last_ms: i64,
}

/// A starred frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StarredFrame {
    pub frame_id: i64,
    pub t_ms: i64,
}

/// What was in front at one moment.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SegmentInfo {
    pub bundle_id: Option<String>,
    pub window: Option<String>,
    pub url: Option<String>,
    pub t_start: i64,
    pub t_end: i64,
}

/// What a stretch of time holds, for deciding what to do with it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SliceSummary {
    pub frames: i64,
    pub bytes: i64,
    pub starred: i64,
    pub transcript_lines: i64,
    /// Time in each app, longest first.
    pub apps: Vec<(Option<String>, i64)>,
    /// The windows that had the most time, longest first.
    pub windows: Vec<String>,
    /// Frames just after the stretch that can't be shown without it, because they build
    /// on frames inside it. Deleting the stretch removes them too.
    pub dependent_frames: i64,
    pub dependent_until_ms: Option<i64>,
}

/// A stretch of speech.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TranscriptSession {
    pub title: Option<String>,
    pub t_start: i64,
    pub t_end: i64,
    pub lines: i64,
}

/// Recording space used by one app.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppStorage {
    pub bundle_id: Option<String>,
    pub bytes: i64,
    pub frames: i64,
}

/// What to list without searching for any words.
#[derive(Clone, Debug, Default)]
pub struct MomentQuery {
    pub bundle_ids: Vec<String>,
    pub starred_only: bool,
    pub transcripts_only: bool,
    pub before_ms: Option<i64>,
    pub limit: u32,
}

/// A moment listed without searching.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Moment {
    pub frame_id: i64,
    pub run_id: i64,
    pub t_ms: i64,
    pub display_uuid: Option<[u8; 16]>,
    pub bundle_id: Option<String>,
    pub window: Option<String>,
    pub url: Option<String>,
    pub snippet: String,
    pub is_transcript: bool,
}

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
    pub fn frame_context(&self, frame_id: i64) -> Result<Option<elodie_store::FrameContext>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        Ok(reader
            .prepare_cached(
                "SELECT s.bundle_id, s.window, s.url, s.profile FROM frame f
                 JOIN segment s ON s.id = f.segment_id WHERE f.id = ?1",
            )?
            .query_row(params![frame_id], |r| {
                Ok(elodie_store::FrameContext {
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
    ) -> Result<elodie_timeline::Timeline> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        Ok(elodie_timeline::load(&reader, display_uuid, from_ms, to_ms, min_duration_ms)?)
    }

    /// The stretches with something recorded for a display, oldest first.
    pub fn recorded_periods(&self, display_uuid: &[u8; 16], min_gap_ms: i64) -> Result<Vec<(i64, i64)>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        Ok(elodie_timeline::recorded_periods(&reader, display_uuid, min_gap_ms)?)
    }

    /// Summarises what was recorded in a period.
    pub fn recap(&self, from_ms: i64, to_ms: i64, bucket_ms: i64) -> Result<elodie_timeline::Recap> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        Ok(elodie_timeline::recap(&reader, from_ms, to_ms, bucket_ms)?)
    }

    /// The text a frame shows, front window first, for answering questions about it.
    pub fn frame_text(&self, frame_id: i64) -> Result<Vec<String>> {
        Ok(self.frame_lines(frame_id)?.into_iter().map(|line| line.text).collect())
    }

    /// The lines of text a frame shows and where they are, front window first.
    pub fn frame_lines(&self, frame_id: i64) -> Result<Vec<FrameTextLine>> {
        let (lines_z, frame_z): (Vec<u8>, Vec<u8>) = {
            let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
            let row = reader
                .prepare_cached(
                    "SELECT r.lines_z, t.lines_z FROM frame_text t
                     JOIN text_run r ON r.id = t.run_id WHERE t.frame_id = ?1",
                )?
                .query_row(params![frame_id], |r| Ok((r.get(0)?, r.get(1)?)))
                .optional()?;
            let Some(row) = row else { return Ok(Vec::new()) };
            row
        };
        let corrupt = |error: std::io::Error| EngineError::Corrupt(error.to_string());
        let lines = elodie_text::codec::decode_lines(&lines_z).map_err(corrupt)?;
        let shown = elodie_text::codec::decode_frame_lines(&frame_z).map_err(corrupt)?;
        let in_order = |front: bool| {
            shown
                .iter()
                .filter_map(|(number, rect)| Some((lines.get(*number as usize)?, *rect)))
                .filter(move |(line, _)| line.is_front == front)
                .map(|(line, rect)| FrameTextLine { text: line.text.clone(), rect })
        };
        Ok(in_order(true).chain(in_order(false)).collect())
    }

    /// Every display with recordings, excluding the one speech is filed under.
    pub fn displays(&self) -> Result<Vec<RecordedDisplay>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        let mut statement = reader.prepare_cached(
            "SELECT d.uuid,
                    (SELECT min(t_ms) FROM frame WHERE display_id = d.id),
                    (SELECT max(t_ms) FROM frame WHERE display_id = d.id),
                    (SELECT width FROM chunk WHERE display_id = d.id ORDER BY id DESC LIMIT 1),
                    (SELECT height FROM chunk WHERE display_id = d.id ORDER BY id DESC LIMIT 1)
             FROM display d",
        )?;
        let rows = statement.query_map([], |r| {
            Ok((
                r.get::<_, Vec<u8>>(0)?,
                r.get::<_, Option<i64>>(1)?,
                r.get::<_, Option<i64>>(2)?,
                r.get::<_, Option<i64>>(3)?,
                r.get::<_, Option<i64>>(4)?,
            ))
        })?;
        let mut displays = Vec::new();
        for row in rows {
            let (uuid, first, last, width, height) = row?;
            let (Ok(uuid), Some(first_ms), Some(last_ms)) = (<[u8; 16]>::try_from(uuid), first, last)
            else {
                continue;
            };
            displays.push(RecordedDisplay {
                uuid,
                width: width.unwrap_or(0),
                height: height.unwrap_or(0),
                first_ms,
                last_ms,
            });
        }
        displays.sort_by_key(|display| std::cmp::Reverse(display.last_ms));
        Ok(displays)
    }

    /// Whether a frame is starred.
    pub fn is_starred(&self, frame_id: i64) -> Result<bool> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        let starred: Option<bool> = reader
            .prepare_cached("SELECT is_starred FROM frame WHERE id = ?1")?
            .query_row(params![frame_id], |r| r.get(0))
            .optional()?;
        Ok(starred.unwrap_or(false))
    }

    /// Starred frames on a display in a period, earliest first.
    pub fn stars(&self, display: &[u8; 16], from_ms: i64, to_ms: i64) -> Result<Vec<StarredFrame>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        let mut statement = reader.prepare_cached(
            "SELECT f.id, f.t_ms FROM frame f
             WHERE f.is_starred = 1 AND f.t_ms >= ?2 AND f.t_ms <= ?3
               AND f.display_id = (SELECT id FROM display WHERE uuid = ?1)
             ORDER BY f.t_ms",
        )?;
        let stars = statement
            .query_map(params![display.as_slice(), from_ms, to_ms], |r| {
                Ok(StarredFrame { frame_id: r.get(0)?, t_ms: r.get(1)? })
            })?
            .collect::<rusqlite::Result<_>>()?;
        Ok(stars)
    }

    /// What was in front on a display at a moment.
    pub fn segment_at(&self, display: &[u8; 16], t_ms: i64) -> Result<Option<SegmentInfo>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        let segment = reader
            .prepare_cached(
                "SELECT bundle_id, window, url, t_start, t_end FROM segment
                 WHERE display_id = (SELECT id FROM display WHERE uuid = ?1)
                   AND type = 0 AND t_start <= ?2
                 ORDER BY t_start DESC LIMIT 1",
            )?
            .query_row(params![display.as_slice(), t_ms], |r| {
                Ok(SegmentInfo {
                    bundle_id: r.get(0)?,
                    window: r.get(1)?,
                    url: r.get(2)?,
                    t_start: r.get(3)?,
                    t_end: r.get(4)?,
                })
            })
            .optional()?;
        Ok(segment)
    }

    /// What a stretch of time holds, across every display.
    pub fn slice_summary(&self, from_ms: i64, to_ms: i64) -> Result<SliceSummary> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        let mut summary = SliceSummary::default();
        let display_ids: Vec<i64> = reader
            .prepare_cached("SELECT id FROM display")?
            .query_map([], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        for display in display_ids {
            let (frames, bytes, starred): (i64, i64, i64) = reader
                .prepare_cached(
                    "SELECT count(*), coalesce(sum(len), 0), coalesce(sum(is_starred), 0)
                     FROM frame WHERE display_id = ?1 AND t_ms >= ?2 AND t_ms <= ?3",
                )?
                .query_row(params![display, from_ms, to_ms], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                })?;
            summary.frames += frames;
            summary.bytes += bytes;
            summary.starred += starred;
            if frames == 0 {
                continue;
            }
            // Nothing after a stretch depends on it if the next frame starts afresh.
            let next_key: Option<i64> = reader
                .prepare_cached(
                    "SELECT min(t_ms) FROM frame WHERE display_id = ?1 AND t_ms > ?2 AND is_sync = 1",
                )?
                .query_row(params![display, to_ms], |r| r.get(0))?;
            let (dependent, last): (i64, Option<i64>) = reader
                .prepare_cached(
                    "SELECT count(*), max(t_ms) FROM frame
                     WHERE display_id = ?1 AND t_ms > ?2 AND t_ms < coalesce(?3, 9223372036854775807)",
                )?
                .query_row(params![display, to_ms, next_key], |r| Ok((r.get(0)?, r.get(1)?)))?;
            summary.dependent_frames += dependent;
            summary.dependent_until_ms = summary.dependent_until_ms.max(last);
        }
        summary.apps = reader
            .prepare_cached(
                "SELECT bundle_id, sum(min(t_end, ?2) - max(t_start, ?1)) AS time
                 FROM segment WHERE type = 0 AND t_end >= ?1 AND t_start <= ?2
                 GROUP BY bundle_id ORDER BY time DESC",
            )?
            .query_map(params![from_ms, to_ms], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        summary.windows = reader
            .prepare_cached(
                "SELECT window FROM segment
                 WHERE type = 0 AND window IS NOT NULL AND t_end >= ?1 AND t_start <= ?2
                 GROUP BY window ORDER BY sum(min(t_end, ?2) - max(t_start, ?1)) DESC LIMIT 5",
            )?
            .query_map(params![from_ms, to_ms], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        summary.transcript_lines = reader
            .prepare_cached("SELECT count(*) FROM transcript_line WHERE t_ms >= ?1 AND t_ms <= ?2")?
            .query_row(params![from_ms, to_ms], |r| r.get(0))?;
        Ok(summary)
    }

    /// Stretches of speech that overlap a period, most recent first.
    pub fn transcript_sessions(
        &self,
        from_ms: i64,
        to_ms: i64,
        limit: u32,
    ) -> Result<Vec<TranscriptSession>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        let mut statement = reader.prepare_cached(
            "SELECT s.window, s.t_start, s.t_end,
                    (SELECT count(*) FROM transcript_line l
                     JOIN text_run r ON r.id = l.run_id WHERE r.segment_id = s.id)
             FROM segment s
             WHERE s.type = 1 AND s.t_end >= ?1 AND s.t_start <= ?2
             ORDER BY s.t_start DESC LIMIT ?3",
        )?;
        let sessions = statement
            .query_map(params![from_ms, to_ms, limit], |r| {
                Ok(TranscriptSession {
                    title: r.get(0)?,
                    t_start: r.get(1)?,
                    t_end: r.get(2)?,
                    lines: r.get(3)?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?;
        Ok(sessions)
    }

    /// How much recording space each app uses, most first. This reads every frame's row,
    /// so don't call it on anything that has to stay responsive.
    pub fn storage_by_app(&self) -> Result<Vec<AppStorage>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        let mut statement = reader.prepare_cached(
            "SELECT s.bundle_id, sum(f.len), count(*) FROM frame f
             LEFT JOIN segment s ON s.id = f.segment_id
             GROUP BY s.bundle_id ORDER BY 2 DESC",
        )?;
        let apps = statement
            .query_map([], |r| {
                Ok(AppStorage { bundle_id: r.get(0)?, bytes: r.get(1)?, frames: r.get(2)? })
            })?
            .collect::<rusqlite::Result<_>>()?;
        Ok(apps)
    }

    /// The stretches of time an app was recorded in, for deleting all of them.
    pub fn app_stretches(&self, bundle_id: &str) -> Result<Vec<(i64, i64)>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        let mut statement = reader.prepare_cached(
            "SELECT t_start, t_end FROM segment WHERE type = 0 AND bundle_id = ?1 ORDER BY t_start",
        )?;
        let stretches = statement
            .query_map(params![bundle_id], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        Ok(stretches)
    }

    /// Lists moments without searching for any words: starred ones, what was said, or the
    /// latest from some apps. Most recent first.
    pub fn moments(&self, query: &MomentQuery) -> Result<Vec<Moment>> {
        let before = query.before_ms.unwrap_or(i64::MAX);
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        let wanted = |bundle: &Option<String>| {
            query.bundle_ids.is_empty()
                || bundle.as_ref().is_some_and(|id| query.bundle_ids.contains(id))
        };
        let limit = query.limit as usize;
        let mut moments = Vec::with_capacity(limit);

        if query.transcripts_only {
            let mut statement = reader.prepare_cached(
                "SELECT r.id, r.t_first, r.lines_z, s.window FROM text_run r
                 LEFT JOIN segment s ON s.id = r.segment_id
                 WHERE r.kind = 1 AND r.t_first < ?1 ORDER BY r.t_first DESC LIMIT ?2",
            )?;
            let rows = statement.query_map(params![before, query.limit], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, Vec<u8>>(2)?,
                    r.get::<_, Option<String>>(3)?,
                ))
            })?;
            for row in rows {
                let (run_id, t_ms, lines_z, window) = row?;
                let snippet = elodie_text::codec::decode_lines(&lines_z)
                    .ok()
                    .and_then(|lines| lines.into_iter().next())
                    .map(|line| line.text)
                    .unwrap_or_default();
                moments.push(Moment {
                    frame_id: 0,
                    run_id,
                    t_ms,
                    display_uuid: None,
                    bundle_id: None,
                    window,
                    url: None,
                    snippet,
                    is_transcript: true,
                });
            }
            return Ok(moments);
        }

        if query.starred_only {
            let mut statement = reader.prepare_cached(
                "SELECT f.id, coalesce(f.run_id, 0), f.t_ms, d.uuid, s.bundle_id, s.window, s.url
                 FROM frame f
                 JOIN display d ON d.id = f.display_id
                 LEFT JOIN segment s ON s.id = f.segment_id
                 WHERE f.is_starred = 1 AND f.t_ms < ?1 ORDER BY f.t_ms DESC",
            )?;
            let rows = statement.query_map(params![before], moment_from_row)?;
            for row in rows {
                let moment = row?;
                if wanted(&moment.bundle_id) {
                    moments.push(moment);
                    if moments.len() == limit {
                        break;
                    }
                }
            }
            return Ok(moments);
        }

        // The latest from each stretch of the chosen apps, so a long stretch is one result.
        let mut segments = reader.prepare_cached(
            "SELECT id, bundle_id FROM segment WHERE type = 0 AND t_end < ?1 ORDER BY t_end DESC",
        )?;
        let mut latest = reader.prepare_cached(
            "SELECT f.id, coalesce(f.run_id, 0), f.t_ms, d.uuid, s.bundle_id, s.window, s.url
             FROM frame f
             JOIN display d ON d.id = f.display_id
             JOIN segment s ON s.id = f.segment_id
             WHERE f.segment_id = ?1 ORDER BY f.t_ms DESC LIMIT 1",
        )?;
        let rows = segments
            .query_map(params![before], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Option<String>>(1)?)))?;
        for row in rows {
            let (segment, bundle) = row?;
            if !wanted(&bundle) {
                continue;
            }
            if let Some(moment) = latest.query_row(params![segment], moment_from_row).optional()? {
                moments.push(moment);
                if moments.len() == limit {
                    break;
                }
            }
        }
        Ok(moments)
    }

    /// Notes a meeting that was transcribed.
    pub fn record_meeting(&self, title: Option<String>, t_start: i64, t_end: i64) -> Result<()> {
        let (reply, response) = crossbeam_channel::bounded(1);
        self.writes
            .as_ref()
            .ok_or(EngineError::Stopped)?
            .send(crate::writer::WriterMessage::Meeting(title, t_start, t_end, reply))
            .map_err(|_| EngineError::Stopped)?;
        response.recv().map_err(|_| EngineError::Stopped)?
    }

    /// Meetings that started in a period, earliest first.
    pub fn meetings(&self, from_ms: i64, to_ms: i64) -> Result<Vec<Meeting>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        let mut statement = reader.prepare_cached(
            "SELECT title, t_start, t_end FROM meeting
             WHERE t_start >= ?1 AND t_start < ?2 ORDER BY t_start",
        )?;
        let meetings = statement
            .query_map(params![from_ms, to_ms], |r| {
                Ok(Meeting { title: r.get(0)?, t_start: r.get(1)?, t_end: r.get(2)? })
            })?
            .collect::<rusqlite::Result<_>>()?;
        Ok(meetings)
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
        Ok(elodie_timeline::active_periods(&reader, periods)?)
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
        Ok(elodie_store::open_reader(
            &self.root.join("vault.db"),
            &elodie_store::DbKey(self.db_key),
        )?)
    }
}

fn moment_from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Moment> {
    let uuid: Vec<u8> = r.get(3)?;
    Ok(Moment {
        frame_id: r.get(0)?,
        run_id: r.get(1)?,
        t_ms: r.get(2)?,
        display_uuid: <[u8; 16]>::try_from(uuid).ok(),
        bundle_id: r.get(4)?,
        window: r.get(5)?,
        url: r.get(6)?,
        snippet: String::new(),
        is_transcript: false,
    })
}
