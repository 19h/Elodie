//! The writer thread: batches logged frames into database transactions.

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, RecvTimeoutError, Sender};
use remind_store::{LoggedFrame, project};
use rusqlite::{Connection, params};

use crate::ocr::{self, OcrBatchOptions, OcrJob, PreparedResult, RunTracker};
use crate::{EngineConfig, EngineError, Shared};

pub(crate) enum WriterMessage {
    Frame(LoggedFrame),
    Sealed([u8; 16]),
    /// Fetches frames waiting for OCR. Runs in the write transaction, because
    /// fetching also records the attempt.
    NextOcrBatch(OcrBatchOptions, Sender<Result<Vec<OcrJob>, EngineError>>),
    /// Stores OCR results in order, replying once they're committed.
    OcrResults(Vec<PreparedResult>, Sender<Result<(), EngineError>>),
    OcrFailed(i64, Sender<Result<(), EngineError>>),
    SetStarred(i64, bool, Sender<Result<(), EngineError>>),
    Meeting(Option<String>, i64, i64, Sender<Result<(), EngineError>>),
    DeleteRange(crate::delete::DeleteRequest, Sender<Result<u64, EngineError>>),
    Transcript(Vec<crate::transcript::SpokenWord>, Option<String>, Sender<Result<(), EngineError>>),
}

impl WriterMessage {
    /// Whether someone is waiting for this, so it shouldn't sit in a batch.
    fn is_urgent(&self) -> bool {
        !matches!(self, WriterMessage::Frame(_) | WriterMessage::Sealed(_))
    }
}

/// How long to wait before retrying a failed commit, such as on a full disk.
const RETRY_DELAY: Duration = Duration::from_secs(5);
/// How many times a batch is retried before anyone waiting on it is told it failed.
const RETRIES_BEFORE_GIVING_UP: u32 = 3;

pub(crate) fn spawn(
    conn: Connection,
    config: EngineConfig,
    shared: Arc<Shared>,
    messages: Receiver<WriterMessage>,
) -> std::io::Result<JoinHandle<()>> {
    std::thread::Builder::new().name("remind-db-writer".to_owned()).spawn(move || {
        crate::set_utility_qos();
        run(conn, &config, &shared, &messages);
    })
}

fn run(
    mut conn: Connection,
    config: &EngineConfig,
    shared: &Shared,
    messages: &Receiver<WriterMessage>,
) {
    // Messages are applied in order, so a seal never overtakes its chunk's frames.
    let mut pending: Vec<WriterMessage> = Vec::new();
    let mut tracker = RunTracker::new(config.run_policy);
    let mut open = true;
    let mut failures = 0;

    while open || !pending.is_empty() {
        if pending.is_empty() {
            match messages.recv() {
                Ok(message) => pending.push(message),
                Err(_) => break,
            }
        }

        let deadline = Instant::now() + config.batch_interval;
        while open && !pending.last().is_some_and(WriterMessage::is_urgent) {
            let wait = deadline.saturating_duration_since(Instant::now());
            match messages.recv_timeout(wait) {
                Ok(message) => pending.push(message),
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => open = false,
            }
        }

        match commit(&mut conn, &pending, &mut tracker) {
            Ok(frames) => {
                shared.indexed_frames.fetch_add(frames, Ordering::Relaxed);
                pending.clear();
                failures = 0;
            }
            // Anything still pending is replayed from the log at next launch, so
            // on shutdown it's safe to give up.
            Err(_) if !open => return,
            Err(error) => {
                // A run in memory may be ahead of what failed to commit.
                tracker = RunTracker::new(config.run_policy);
                failures += 1;
                // Someone may be waiting on this batch, and it may never succeed. Frames
                // can wait, because they're safe in the log, but a person can't, and one
                // bad request mustn't stop everything else from being stored.
                if failures >= RETRIES_BEFORE_GIVING_UP {
                    give_up_on_requests(&mut pending, &error);
                    failures = 0;
                }
                std::thread::sleep(RETRY_DELAY);
            }
        }
    }
}

/// Tells everyone waiting that their request failed, and drops those requests. What's left
/// is only frames, which get retried.
fn give_up_on_requests(pending: &mut Vec<WriterMessage>, error: &rusqlite::Error) {
    let failure = || EngineError::Corrupt(format!("the change couldn't be saved: {error}"));
    for message in pending.drain(..).collect::<Vec<_>>() {
        match message {
            WriterMessage::Frame(_) | WriterMessage::Sealed(_) => pending.push(message),
            WriterMessage::NextOcrBatch(_, reply) => {
                let _ = reply.send(Err(failure()));
            }
            WriterMessage::OcrResults(_, reply)
            | WriterMessage::OcrFailed(_, reply)
            | WriterMessage::SetStarred(_, _, reply)
            | WriterMessage::Meeting(_, _, _, reply)
            | WriterMessage::Transcript(_, _, reply) => {
                let _ = reply.send(Err(failure()));
            }
            WriterMessage::DeleteRange(_, reply) => {
                let _ = reply.send(Err(failure()));
            }
        }
    }
}

/// Replies are sent only after the transaction commits, so whoever is waiting never
/// sees a success that didn't reach the database.
enum Reply {
    Batch(Sender<Result<Vec<OcrJob>, EngineError>>, Vec<OcrJob>),
    Done(Sender<Result<(), EngineError>>),
    Deleted(Sender<Result<u64, EngineError>>, crate::delete::Outcome),
}

fn commit(
    conn: &mut Connection,
    messages: &[WriterMessage],
    tracker: &mut RunTracker,
) -> rusqlite::Result<u64> {
    let tx = conn.transaction()?;
    let mut frames = 0;
    let mut replies = Vec::new();

    for message in messages {
        match message {
            WriterMessage::Frame(frame) => {
                project::apply_one(&tx, frame)?;
                frames += 1;
            }
            WriterMessage::Sealed(uuid) => {
                tx.execute("UPDATE chunk SET sealed = 1 WHERE uuid = ?1", params![uuid.as_slice()])?;
            }
            WriterMessage::NextOcrBatch(options, reply) => {
                replies.push(Reply::Batch(reply.clone(), ocr::next_batch(&tx, *options)?));
            }
            WriterMessage::OcrResults(results, reply) => {
                for result in results {
                    ocr::store_result(&tx, tracker, result)?;
                }
                replies.push(Reply::Done(reply.clone()));
            }
            WriterMessage::OcrFailed(frame_id, reply) => {
                ocr::mark_failed(&tx, *frame_id)?;
                replies.push(Reply::Done(reply.clone()));
            }
            WriterMessage::SetStarred(frame_id, starred, reply) => {
                tx.execute(
                    "UPDATE frame SET is_starred = ?2 WHERE id = ?1",
                    params![frame_id, starred],
                )?;
                replies.push(Reply::Done(reply.clone()));
            }
            WriterMessage::Meeting(title, t_start, t_end, reply) => {
                tx.execute(
                    "INSERT INTO meeting(title, t_start, t_end) VALUES (?1, ?2, ?3)",
                    params![title, t_start, t_end],
                )?;
                replies.push(Reply::Done(reply.clone()));
            }
            WriterMessage::Transcript(words, title, reply) => {
                crate::transcript::store(&tx, tracker, words, title.as_deref())?;
                replies.push(Reply::Done(reply.clone()));
            }
            WriterMessage::DeleteRange(request, reply) => {
                let outcome = crate::delete::apply(&tx, request)?;
                // The runs in memory may just have been deleted or rewritten.
                *tracker = RunTracker::new(tracker.policy());
                replies.push(Reply::Deleted(reply.clone(), outcome));
            }
        }
    }
    tx.commit()?;

    for reply in replies {
        match reply {
            Reply::Batch(sender, jobs) => {
                let _ = sender.send(Ok(jobs));
            }
            Reply::Done(sender) => {
                let _ = sender.send(Ok(()));
            }
            Reply::Deleted(sender, outcome) => {
                crate::delete::finish(conn, &outcome.files_to_move, &outcome.files_to_remove);
                if outcome.reclaim {
                    crate::delete::reclaim_space(conn);
                }
                let _ = sender.send(Ok(outcome.frames_removed));
            }
        }
    }
    Ok(frames)
}
