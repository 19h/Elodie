//! Runs the write path: the appender and database writer threads, and recovery.
//!
//! ```text
//! append() ──bounded──▶ appender thread ──▶ chunk log  (durable against SIGKILL)
//!                            │
//!                            └──unbounded──▶ writer thread ──▶ database
//! ```
//!
//! The appender never touches SQLite, so a stalled database can't delay a frame
//! reaching the log. The writer's queue holds only small metadata records, and
//! anything lost from it is replayed from the log on the next launch.

mod appender;
mod ocr;
mod read;
mod recovery;
mod search;
mod writer;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use crossbeam_channel::{Sender, TrySendError, bounded, unbounded};
use remind_store::{DbKey, schema};
use remind_vault::{MasterKey, VaultError};
use rusqlite::Connection;

pub use ocr::{OcrBatchOptions, OcrJob, OcrResult};
pub use read::{FrameRef, Gop, GopSample};
pub use recovery::RecoveryReport;
pub use search::SearchSession;
pub use remind_store::FrameContext;
pub use remind_text::{OcrLine, Rect, RunPolicy};

use appender::AppendRequest;

/// Errors opening or querying the engine.
#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error(transparent)]
    Vault(#[from] VaultError),
    #[error(transparent)]
    Database(#[from] rusqlite::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("the engine has stopped")]
    Stopped,
    #[error("no such frame")]
    NoSuchFrame,
    #[error("frame data is corrupt: {0}")]
    Corrupt(String),
}

pub type Result<T> = std::result::Result<T, EngineError>;

/// Tunable limits. Defaults are the production values.
#[derive(Clone, Debug)]
pub struct EngineConfig {
    /// A chunk is replaced at the next keyframe after reaching this age.
    pub chunk_max_age: Duration,
    /// A chunk is replaced at the next keyframe after reaching this size.
    pub chunk_max_bytes: u64,
    /// How often dirty chunks are flushed to the drive. This bounds what a power
    /// cut can lose.
    pub sync_interval: Duration,
    /// How long the writer collects frames before committing a batch.
    pub batch_interval: Duration,
    /// Samples waiting for the appender. When full, samples are dropped.
    pub sample_queue: usize,
    /// How frames are grouped into text runs.
    pub run_policy: RunPolicy,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            chunk_max_age: Duration::from_secs(300),
            chunk_max_bytes: 64 * 1024 * 1024,
            sync_interval: Duration::from_secs(5),
            batch_interval: Duration::from_secs(1),
            sample_queue: 8,
            run_policy: RunPolicy::default(),
        }
    }
}

/// An encoded video sample and what was on screen for it.
#[derive(Clone, Debug)]
pub struct Sample {
    pub display_uuid: [u8; 16],
    pub width: u32,
    pub height: u32,
    /// The codec's parameter sets. A change starts a new chunk.
    pub parameter_sets: Arc<[u8]>,
    pub wall_ms: i64,
    pub mono_ns: u64,
    pub is_sync: bool,
    pub context: FrameContext,
    pub data: Vec<u8>,
}

/// What happened to a sample passed to [`Engine::append`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppendOutcome {
    /// Queued for the log.
    Accepted,
    /// Dropped because the queue is full. The P-frame chain is broken, so the
    /// next sample must be a keyframe.
    DroppedQueueFull,
    /// Dropped because a keyframe is required next. Force one.
    NeedsKeyframe,
}

/// Counters for monitoring and tests.
#[derive(Clone, Debug, Default)]
pub struct EngineStats {
    pub logged_frames: u64,
    pub indexed_frames: u64,
    pub dropped_frames: u64,
    pub append_failures: u64,
    pub disk_full: bool,
}

#[derive(Default)]
struct DisplayState {
    parameter_sets: Option<Arc<[u8]>>,
    needs_keyframe: bool,
}

/// State shared between the caller and the worker threads.
#[derive(Default)]
struct Shared {
    displays: Mutex<HashMap<[u8; 16], DisplayState>>,
    logged_frames: AtomicU64,
    indexed_frames: AtomicU64,
    dropped_frames: AtomicU64,
    append_failures: AtomicU64,
    /// The `mono_ns` of the newest sample known to be in the log.
    logged_watermark: AtomicU64,
    disk_full: AtomicBool,
}

impl Shared {
    /// Requires a keyframe next on this display. Called when its P-frame chain
    /// breaks.
    fn require_keyframe(&self, display: &[u8; 16]) {
        if let Ok(mut displays) = self.displays.lock() {
            displays.entry(*display).or_default().needs_keyframe = true;
        }
    }
}

/// The write path and frame reader for one vault.
pub struct Engine {
    root: PathBuf,
    master: MasterKey,
    db_key: [u8; 32],
    shared: Arc<Shared>,
    samples: Option<Sender<AppendRequest>>,
    writes: Option<Sender<writer::WriterMessage>>,
    appender: Option<JoinHandle<()>>,
    writer: Option<JoinHandle<()>>,
    reader: Mutex<Connection>,
}

impl Engine {
    /// Opens a vault, creating it if needed, and recovers from any crash.
    ///
    /// The vault can't be modified until this finishes.
    pub fn open(
        root: &Path,
        master: MasterKey,
        config: EngineConfig,
    ) -> Result<(Self, RecoveryReport)> {
        std::fs::create_dir_all(root)?;
        let db_key = master.database_key();
        let db_path = root.join("vault.db");

        let mut writer_conn = remind_store::open_writer(&db_path, &DbKey(db_key))?;
        schema::migrate(&mut writer_conn)?;

        let report = recovery::recover(root, &master, &mut writer_conn)?;

        let reader = remind_store::open_reader(&db_path, &DbKey(db_key))?;
        let shared = Arc::new(Shared::default());

        let (sample_tx, sample_rx) = bounded(config.sample_queue);
        let (logged_tx, logged_rx) = unbounded();

        let appender = appender::spawn(
            root.to_owned(),
            master.clone(),
            config.clone(),
            Arc::clone(&shared),
            sample_rx,
            logged_tx.clone(),
        )?;
        let writer = writer::spawn(writer_conn, config, Arc::clone(&shared), logged_rx)?;

        Ok((
            Self {
                root: root.to_owned(),
                master,
                db_key,
                shared,
                samples: Some(sample_tx),
                writes: Some(logged_tx),
                appender: Some(appender),
                writer: Some(writer),
                reader: Mutex::new(reader),
            },
            report,
        ))
    }

    /// Queues a sample for the log. This never blocks, so it's safe to call from
    /// a capture thread.
    pub fn append(&self, sample: Sample) -> Result<AppendOutcome> {
        let samples = self.samples.as_ref().ok_or(EngineError::Stopped)?;
        let mut displays = self.shared.displays.lock().map_err(|_| EngineError::Stopped)?;
        let state = displays.entry(sample.display_uuid).or_default();

        // A new display or new parameter sets start a new chunk, and a chunk
        // has to begin with a keyframe.
        let parameters_changed =
            state.parameter_sets.as_deref() != Some(&*sample.parameter_sets);
        if (state.needs_keyframe || parameters_changed) && !sample.is_sync {
            state.needs_keyframe = true;
            self.shared.dropped_frames.fetch_add(1, Ordering::Relaxed);
            return Ok(AppendOutcome::NeedsKeyframe);
        }

        let parameter_sets = Arc::clone(&sample.parameter_sets);
        match samples.try_send(AppendRequest::Sample(sample)) {
            Ok(()) => {
                state.needs_keyframe = false;
                state.parameter_sets = Some(parameter_sets);
                Ok(AppendOutcome::Accepted)
            }
            Err(TrySendError::Full(_)) => {
                state.needs_keyframe = true;
                self.shared.dropped_frames.fetch_add(1, Ordering::Relaxed);
                Ok(AppendOutcome::DroppedQueueFull)
            }
            Err(TrySendError::Disconnected(_)) => Err(EngineError::Stopped),
        }
    }

    /// Seals open chunks, so the next sample per display starts a new one with a
    /// keyframe. Call before sleep. Blocks until the chunks are on the drive.
    pub fn seal_all(&self) -> Result<()> {
        let samples = self.samples.as_ref().ok_or(EngineError::Stopped)?;
        let (done_tx, done_rx) = bounded(1);
        samples.send(AppendRequest::SealAll(done_tx)).map_err(|_| EngineError::Stopped)?;
        done_rx.recv().map_err(|_| EngineError::Stopped)
    }

    pub fn stats(&self) -> EngineStats {
        let shared = &self.shared;
        EngineStats {
            logged_frames: shared.logged_frames.load(Ordering::Relaxed),
            indexed_frames: shared.indexed_frames.load(Ordering::Relaxed),
            dropped_frames: shared.dropped_frames.load(Ordering::Relaxed),
            append_failures: shared.append_failures.load(Ordering::Relaxed),
            disk_full: shared.disk_full.load(Ordering::Relaxed),
        }
    }

    /// The `mono_ns` of the newest sample that has reached the log. Anything at
    /// or below this survives SIGKILL.
    pub fn logged_watermark(&self) -> u64 {
        self.shared.logged_watermark.load(Ordering::Acquire)
    }

    /// Finishes queued work, seals chunks, and commits. Dropping the engine does
    /// this too, without reporting problems.
    pub fn close(mut self) -> Result<()> {
        self.shut_down()
    }

    fn shut_down(&mut self) -> Result<()> {
        self.samples.take();
        self.writes.take();
        for handle in [self.appender.take(), self.writer.take()].into_iter().flatten() {
            handle.join().map_err(|_| EngineError::Stopped)?;
        }
        Ok(())
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        let _ = self.shut_down();
    }
}

/// Lowers the current thread's priority, so background work yields to the UI.
fn set_utility_qos() {
    // SAFETY: this only changes the calling thread's scheduling class.
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_UTILITY, 0);
    }
}
