//! The writer thread: batches logged frames into database transactions.

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, RecvTimeoutError};
use remind_store::{LoggedFrame, project};
use rusqlite::{Connection, params};

use crate::{EngineConfig, Shared};

pub(crate) enum WriterMessage {
    Frame(LoggedFrame),
    Sealed([u8; 16]),
}

/// How long to wait before retrying a failed commit, such as on a full disk.
const RETRY_DELAY: Duration = Duration::from_secs(5);

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
    let mut open = true;

    while open || !pending.is_empty() {
        if pending.is_empty() {
            match messages.recv() {
                Ok(message) => pending.push(message),
                Err(_) => break,
            }
        }

        let deadline = Instant::now() + config.batch_interval;
        while open {
            let wait = deadline.saturating_duration_since(Instant::now());
            match messages.recv_timeout(wait) {
                Ok(message) => pending.push(message),
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => open = false,
            }
        }

        match commit(&mut conn, &pending) {
            Ok(frames) => {
                shared.indexed_frames.fetch_add(frames, Ordering::Relaxed);
                pending.clear();
            }
            // Anything still pending is replayed from the log at next launch, so
            // on shutdown it's safe to give up.
            Err(_) if !open => return,
            Err(_) => std::thread::sleep(RETRY_DELAY),
        }
    }
}

fn commit(conn: &mut Connection, messages: &[WriterMessage]) -> rusqlite::Result<u64> {
    let tx = conn.transaction()?;
    let mut frames = 0;
    for message in messages {
        match message {
            WriterMessage::Frame(frame) => {
                project::apply_one(&tx, frame)?;
                frames += 1;
            }
            WriterMessage::Sealed(uuid) => {
                tx.execute("UPDATE chunk SET sealed = 1 WHERE uuid = ?1", params![uuid.as_slice()])?;
            }
        }
    }
    tx.commit()?;
    Ok(frames)
}
