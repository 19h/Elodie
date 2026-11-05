//! The durable OCR queue.
//!
//! A frame's OCR state lives in the database and pixels stay in the log, so OCR can
//! fall behind indefinitely without using memory and can pick up after a crash. An
//! attempt is recorded before OCR runs, so a frame that crashes the recogniser
//! gets given up on rather than crashing every launch.

use std::collections::HashMap;

use rayon::prelude::*;
use remind_store::project::decode_front_rect;
use remind_store::text::{self, ocr_state};
use remind_text::{OcrLine, OpenRun, PreparedLine, Rect, RunPolicy, prepare_lines};
use rusqlite::{OptionalExtension, Transaction, params};

use crate::writer::WriterMessage;
use crate::{Engine, EngineError, Result};

/// Attempts allowed before a frame is given up on.
const MAX_ATTEMPTS: i64 = 3;

/// When OCR is further behind than this, frames that were soon replaced get set
/// aside for later, and the ones that stayed on screen go first.
const BEHIND_MS: i64 = 60_000;

/// A frame counts as settled if nothing replaced it for this long, which is what
/// someone was likely reading.
const SETTLED_MS: i64 = 4_000;

/// What to fetch.
#[derive(Clone, Copy, Debug)]
pub struct OcrBatchOptions {
    pub max: u32,
    /// The current time, for working out how far behind OCR is.
    pub now_ms: i64,
    /// Whether to include frames set aside earlier. Pass this when idle.
    pub include_deferred: bool,
}

/// A frame ready for OCR.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OcrJob {
    pub frame_id: i64,
    pub t_ms: i64,
    pub attempt: u32,
}

/// What OCR found in a frame.
#[derive(Clone, Debug)]
pub struct OcrResult {
    pub frame_id: i64,
    pub lines: Vec<OcrLine>,
}

/// A result that's been normalised, ready to apply in order.
pub(crate) struct PreparedResult {
    frame_id: i64,
    lines: Vec<PreparedLine>,
}

/// Open runs by display, kept in memory between commits.
pub(crate) struct RunTracker {
    policy: RunPolicy,
    open: HashMap<i64, OpenRun>,
}

impl RunTracker {
    pub(crate) fn new(policy: RunPolicy) -> Self {
        Self { policy, open: HashMap::new() }
    }

    pub(crate) fn policy(&self) -> RunPolicy {
        self.policy
    }
}

/// Defers frames that were quickly replaced, when OCR is behind.
fn defer_unsettled(tx: &Transaction<'_>, now_ms: i64) -> rusqlite::Result<()> {
    let oldest: Option<i64> = tx
        .query_row(
            "SELECT min(t_ms) FROM frame WHERE ocr_state = ?1",
            params![ocr_state::PENDING],
            |r| r.get(0),
        )
        .optional()?
        .flatten();
    if oldest.is_none_or(|oldest| now_ms - oldest <= BEHIND_MS) {
        return Ok(());
    }
    tx.execute(
        "UPDATE frame SET ocr_state = ?1
         WHERE id IN (
             SELECT id FROM (
                 SELECT id, ocr_state AS state,
                        lead(t_ms) OVER (PARTITION BY display_id ORDER BY t_ms) - t_ms AS gap
                 FROM frame
                 WHERE ocr_state IN (?1, ?2)
             )
             WHERE state = ?2 AND gap < ?3
         )",
        params![ocr_state::DEFERRED, ocr_state::PENDING, SETTLED_MS],
    )?;
    Ok(())
}

/// Fetches the next frames, recording the attempt before OCR runs.
pub(crate) fn next_batch(
    tx: &Transaction<'_>,
    options: OcrBatchOptions,
) -> rusqlite::Result<Vec<OcrJob>> {
    defer_unsettled(tx, options.now_ms)?;

    let exhausted = "UPDATE frame SET ocr_state = ?1
                     WHERE ocr_state IN (?2, ?3) AND ocr_attempts >= ?4";
    tx.execute(
        exhausted,
        params![ocr_state::FAILED, ocr_state::PENDING, ocr_state::DEFERRED, MAX_ATTEMPTS],
    )?;

    // Pending comes first, because deferred frames only run when nothing else is left.
    let last_state = if options.include_deferred { ocr_state::DEFERRED } else { ocr_state::PENDING };
    let jobs: Vec<OcrJob> = tx
        .prepare_cached(
            "SELECT id, t_ms, ocr_attempts FROM frame
             WHERE ocr_state IN (?1, ?2) ORDER BY ocr_state, t_ms LIMIT ?3",
        )?
        .query_map(params![ocr_state::PENDING, last_state, options.max], |r| {
            Ok(OcrJob {
                frame_id: r.get(0)?,
                t_ms: r.get(1)?,
                attempt: r.get::<_, u32>(2)? + 1,
            })
        })?
        .collect::<rusqlite::Result<_>>()?;

    for job in &jobs {
        tx.execute(
            "UPDATE frame SET ocr_attempts = ocr_attempts + 1 WHERE id = ?1",
            params![job.frame_id],
        )?;
    }
    Ok(jobs)
}

/// Adds a frame's text to a run. All of this commits with the frame's state, so a
/// crash can't leave one without the other.
pub(crate) fn store_result(
    tx: &Transaction<'_>,
    tracker: &mut RunTracker,
    result: &PreparedResult,
) -> rusqlite::Result<()> {
    let row: Option<(i64, Option<i64>, i64)> = tx
        .query_row(
            "SELECT t_ms, segment_id, display_id FROM frame WHERE id = ?1",
            params![result.frame_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    // The frame may have been deleted while OCR ran.
    let Some((t_ms, segment_id, display_id)) = row else {
        return Ok(());
    };

    // A frame with no text has nothing to find.
    if result.lines.is_empty() {
        tx.execute(
            "UPDATE frame SET ocr_state = ?2 WHERE id = ?1",
            params![result.frame_id, ocr_state::DONE],
        )?;
        return Ok(());
    }

    let policy = tracker.policy;
    let joins = tracker
        .open
        .get(&display_id)
        .is_some_and(|run| run.accepts(policy, segment_id, t_ms, &result.lines));
    if !joins {
        tracker.open.insert(display_id, OpenRun::new(segment_id, display_id, t_ms, &result.lines));
    }
    // It was just inserted if it wasn't already there.
    let Some(run) = tracker.open.get_mut(&display_id) else {
        return Ok(());
    };

    let shown = run.add(t_ms, &result.lines);
    let run_id = text::write_run(tx, run)?;
    text::write_frame_text(tx, result.frame_id, run_id, &shown)
}

pub(crate) fn mark_failed(tx: &Transaction<'_>, frame_id: i64) -> rusqlite::Result<()> {
    // It stays queued until its attempts run out. `next_batch` retires it then.
    tx.execute(
        "UPDATE frame SET ocr_state = CASE WHEN ocr_attempts >= ?2 THEN ?3 ELSE ocr_state END
         WHERE id = ?1",
        params![frame_id, MAX_ATTEMPTS, ocr_state::FAILED],
    )?;
    Ok(())
}

impl Engine {
    fn writes(&self) -> Result<&crossbeam_channel::Sender<WriterMessage>> {
        self.writes.as_ref().ok_or(EngineError::Stopped)
    }

    /// Fetches frames waiting for OCR.
    pub fn next_ocr_batch(&self, options: OcrBatchOptions) -> Result<Vec<OcrJob>> {
        let (reply, response) = crossbeam_channel::bounded(1);
        self.writes()?
            .send(WriterMessage::NextOcrBatch(options, reply))
            .map_err(|_| EngineError::Stopped)?;
        response.recv().map_err(|_| EngineError::Stopped)?
    }

    /// Stores OCR results and waits until they're committed.
    ///
    /// Normalising runs across all results in parallel. This matters when working
    /// through a backlog. Results are then applied in order, because a run depends
    /// on which frame came before.
    pub fn submit_ocr(&self, results: Vec<OcrResult>) -> Result<()> {
        let front_rects = self.front_rects(&results)?;
        let prepared: Vec<PreparedResult> = results
            .into_par_iter()
            .map(|result| {
                let front = front_rects.get(&result.frame_id).copied();
                PreparedResult {
                    frame_id: result.frame_id,
                    lines: prepare_lines(result.lines, front),
                }
            })
            .collect();

        let (reply, response) = crossbeam_channel::bounded(1);
        self.writes()?
            .send(WriterMessage::OcrResults(prepared, reply))
            .map_err(|_| EngineError::Stopped)?;
        response.recv().map_err(|_| EngineError::Stopped)?
    }

    /// Records that OCR couldn't process a frame.
    pub fn fail_ocr(&self, frame_id: i64) -> Result<()> {
        let (reply, response) = crossbeam_channel::bounded(1);
        self.writes()?
            .send(WriterMessage::OcrFailed(frame_id, reply))
            .map_err(|_| EngineError::Stopped)?;
        response.recv().map_err(|_| EngineError::Stopped)?
    }

    fn front_rects(&self, results: &[OcrResult]) -> Result<HashMap<i64, Rect>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        let mut statement = reader.prepare_cached("SELECT front_rect FROM frame WHERE id = ?1")?;
        let mut rects = HashMap::with_capacity(results.len());
        for result in results {
            let bytes: Option<Vec<u8>> = statement
                .query_row(params![result.frame_id], |r| r.get(0))
                .optional()?
                .flatten();
            if let Some(scaled) = bytes.as_deref().and_then(decode_front_rect) {
                rects.insert(result.frame_id, Rect::from_scaled(scaled));
            }
        }
        Ok(rects)
    }
}
