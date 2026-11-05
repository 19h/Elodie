//! The Swift-facing API. Swift calls Rust and never the other way around.

use std::path::Path;
use std::sync::Arc;

use remind_engine::{Engine, EngineConfig, EngineError, FrameContext, Sample};
use remind_vault::MasterKey;

uniffi::setup_scaffolding!();

/// An error the app can act on or show.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("the key must be 32 bytes, got {actual}")]
    InvalidKey { actual: u32 },
    #[error("a display ID must be 16 bytes, got {actual}")]
    InvalidDisplay { actual: u32 },
    #[error("no such frame")]
    NoSuchFrame,
    #[error("the core has stopped")]
    Stopped,
    #[error("storage failed: {message}")]
    Storage { message: String },
}

impl From<EngineError> for CoreError {
    fn from(error: EngineError) -> Self {
        match error {
            EngineError::Stopped => CoreError::Stopped,
            EngineError::NoSuchFrame => CoreError::NoSuchFrame,
            other => CoreError::Storage { message: other.to_string() },
        }
    }
}

impl From<rusqlite::Error> for CoreError {
    fn from(error: rusqlite::Error) -> Self {
        CoreError::Storage { message: error.to_string() }
    }
}

fn display_id(bytes: &[u8]) -> Result<[u8; 16], CoreError> {
    let actual = u32::try_from(bytes.len()).unwrap_or(u32::MAX);
    bytes.try_into().map_err(|_| CoreError::InvalidDisplay { actual })
}

/// What the running core was built with.
#[derive(Debug, uniffi::Record)]
pub struct CoreInfo {
    pub version: String,
    pub sqlite_version: String,
    pub cipher_provider: String,
}

/// What recovery found when the vault was opened.
#[derive(Debug, uniffi::Record)]
pub struct RecoveryInfo {
    pub chunks_checked: u64,
    pub frames_replayed: u64,
    pub frames_removed: u64,
    pub chunks_trimmed: u64,
    pub chunks_removed: u64,
    pub chunks_unreadable: u64,
    pub duration_ms: u64,
}

/// An encoded video sample and what was on screen for it.
#[derive(Debug, uniffi::Record)]
pub struct SampleInput {
    pub display_uuid: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub parameter_sets: Vec<u8>,
    pub wall_ms: i64,
    pub mono_ns: u64,
    pub is_sync: bool,
    pub bundle_id: Option<String>,
    pub window: Option<String>,
    pub url: Option<String>,
    pub profile: Option<String>,
    pub data: Vec<u8>,
}

/// What happened to an appended sample.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppendOutcome {
    Accepted,
    /// Dropped because the queue is full. Force a keyframe next.
    DroppedQueueFull,
    /// Dropped because a keyframe is required next. Force one.
    NeedsKeyframe,
}

/// A frame's identity and when it was captured.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct FrameRef {
    pub id: i64,
    pub t_ms: i64,
}

/// One sample in a group of pictures.
#[derive(Debug, uniffi::Record)]
pub struct GopSample {
    pub frame_id: i64,
    pub t_ms: i64,
    pub is_sync: bool,
    pub data: Vec<u8>,
}

/// A keyframe and the samples that depend on it.
#[derive(Debug, uniffi::Record)]
pub struct Gop {
    pub width: u32,
    pub height: u32,
    pub parameter_sets: Vec<u8>,
    pub samples: Vec<GopSample>,
    /// The index in `samples` of the frame asked for.
    pub target: u32,
}

/// Counters for monitoring.
#[derive(Debug, uniffi::Record)]
pub struct CoreStats {
    pub logged_frames: u64,
    pub indexed_frames: u64,
    pub dropped_frames: u64,
    pub append_failures: u64,
    pub disk_full: bool,
}

/// An open vault.
#[derive(uniffi::Object)]
pub struct Core {
    engine: Engine,
    recovery: RecoveryInfo,
}

#[uniffi::export]
impl Core {
    /// Opens the vault in the directory `root`, creating it if needed, and
    /// recovers from any crash. This can take a moment, so don't call it from the
    /// main thread.
    #[uniffi::constructor]
    pub fn open(root: String, master_key: Vec<u8>) -> Result<Arc<Self>, CoreError> {
        let actual = u32::try_from(master_key.len()).unwrap_or(u32::MAX);
        let key: [u8; 32] =
            master_key.try_into().map_err(|_| CoreError::InvalidKey { actual })?;
        let (engine, report) =
            Engine::open(Path::new(&root), MasterKey::from_bytes(key), EngineConfig::default())?;
        let recovery = RecoveryInfo {
            chunks_checked: report.chunks_checked,
            frames_replayed: report.frames_replayed,
            frames_removed: report.frames_removed,
            chunks_trimmed: report.chunks_trimmed,
            chunks_removed: report.chunks_removed,
            chunks_unreadable: report.chunks_unreadable,
            duration_ms: report.duration.as_millis() as u64,
        };
        Ok(Arc::new(Self { engine, recovery }))
    }

    pub fn info(&self) -> Result<CoreInfo, CoreError> {
        let reader = self.engine.open_reader()?;
        let sqlite_version = reader.query_row("SELECT sqlite_version()", [], |r| r.get(0))?;
        let cipher_provider = reader.query_row("PRAGMA cipher_provider", [], |r| r.get(0))?;
        Ok(CoreInfo {
            version: env!("CARGO_PKG_VERSION").to_owned(),
            sqlite_version,
            cipher_provider,
        })
    }

    pub fn recovery(&self) -> RecoveryInfo {
        let r = &self.recovery;
        RecoveryInfo {
            chunks_checked: r.chunks_checked,
            frames_replayed: r.frames_replayed,
            frames_removed: r.frames_removed,
            chunks_trimmed: r.chunks_trimmed,
            chunks_removed: r.chunks_removed,
            chunks_unreadable: r.chunks_unreadable,
            duration_ms: r.duration_ms,
        }
    }

    /// Queues a sample for the log. This never blocks.
    pub fn append_sample(&self, sample: SampleInput) -> Result<AppendOutcome, CoreError> {
        let outcome = self.engine.append(Sample {
            display_uuid: display_id(&sample.display_uuid)?,
            width: sample.width,
            height: sample.height,
            parameter_sets: Arc::from(sample.parameter_sets),
            wall_ms: sample.wall_ms,
            mono_ns: sample.mono_ns,
            is_sync: sample.is_sync,
            context: FrameContext {
                bundle_id: sample.bundle_id,
                window: sample.window.filter(|w| !w.is_empty()),
                url: sample.url.filter(|u| !u.is_empty()),
                profile: sample.profile.filter(|p| !p.is_empty()),
            },
            data: sample.data,
        })?;
        Ok(match outcome {
            remind_engine::AppendOutcome::Accepted => AppendOutcome::Accepted,
            remind_engine::AppendOutcome::DroppedQueueFull => AppendOutcome::DroppedQueueFull,
            remind_engine::AppendOutcome::NeedsKeyframe => AppendOutcome::NeedsKeyframe,
        })
    }

    /// Seals open chunks and waits until they're on the drive. Call before sleep.
    pub fn seal_all(&self) -> Result<(), CoreError> {
        Ok(self.engine.seal_all()?)
    }

    /// The latest frame at or before `t_ms` on a display.
    pub fn lookup(&self, display_uuid: Vec<u8>, t_ms: i64) -> Result<Option<FrameRef>, CoreError> {
        let frame = self.engine.lookup(&display_id(&display_uuid)?, t_ms)?;
        Ok(frame.map(|f| FrameRef { id: f.id, t_ms: f.t_ms }))
    }

    /// Reads the group of pictures containing a frame.
    pub fn read_gop(&self, frame_id: i64) -> Result<Gop, CoreError> {
        let gop = self.engine.read_gop(frame_id)?;
        Ok(Gop {
            width: gop.width,
            height: gop.height,
            parameter_sets: gop.parameter_sets,
            target: gop.target as u32,
            samples: gop
                .samples
                .into_iter()
                .map(|s| GopSample {
                    frame_id: s.frame_id,
                    t_ms: s.t_ms,
                    is_sync: s.is_sync,
                    data: s.data,
                })
                .collect(),
        })
    }

    pub fn stats(&self) -> CoreStats {
        let stats = self.engine.stats();
        CoreStats {
            logged_frames: stats.logged_frames,
            indexed_frames: stats.indexed_frames,
            dropped_frames: stats.dropped_frames,
            append_failures: stats.append_failures,
            disk_full: stats.disk_full,
        }
    }
}
