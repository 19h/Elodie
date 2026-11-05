//! The Swift-facing API. Swift calls Rust and never the other way around.

use std::path::Path;
use std::sync::Arc;

use remind_engine::{
    Engine, EngineConfig, EngineError, FrameContext, OcrBatchOptions, OcrLine, OcrResult, Rect,
    Sample, SearchSession,
};
use remind_search::{Facets, Order, Query};
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

/// A rectangle as fractions of the frame, with the origin at the top left.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct NormalizedRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl From<Rect> for NormalizedRect {
    fn from(rect: Rect) -> Self {
        Self { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
    }
}

impl From<NormalizedRect> for Rect {
    fn from(rect: NormalizedRect) -> Self {
        Self { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
    }
}

fn scaled(value: f32) -> u16 {
    (value.clamp(0.0, 1.0) * f32::from(u16::MAX)).round() as u16
}

/// A frame waiting for OCR.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct OcrJob {
    pub frame_id: i64,
    pub t_ms: i64,
    pub attempt: u32,
}

/// A piece of text OCR found.
#[derive(Debug, uniffi::Record)]
pub struct OcrLineInput {
    pub text: String,
    pub rect: NormalizedRect,
}

/// What OCR found in a frame.
#[derive(Debug, uniffi::Record)]
pub struct OcrResultInput {
    pub frame_id: i64,
    pub lines: Vec<OcrLineInput>,
}

/// The order of search results.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SearchOrder {
    Relevance,
    Newest,
}

/// Limits on what's searched.
#[derive(Debug, uniffi::Record)]
pub struct SearchFacets {
    pub bundle_ids: Vec<String>,
    pub from_ms: Option<i64>,
    pub to_ms: Option<i64>,
    pub starred_only: bool,
}

/// A moment that matched a search.
#[derive(Debug, uniffi::Record)]
pub struct SearchHit {
    pub frame_id: i64,
    pub run_id: i64,
    pub t_ms: i64,
    pub bundle_id: Option<String>,
    pub window: Option<String>,
    pub url: Option<String>,
    pub rects: Vec<NormalizedRect>,
    pub snippet: String,
}

/// A page of search results.
#[derive(Debug, uniffi::Record)]
pub struct SearchPage {
    pub hits: Vec<SearchHit>,
    pub has_more: bool,
}

/// A search in progress.
#[derive(uniffi::Object)]
pub struct SearchHandle {
    session: SearchSession,
}

#[uniffi::export]
impl SearchHandle {
    /// Fetches the next page. This can take a moment, so don't call it on the main thread.
    pub fn next_page(&self) -> Result<SearchPage, CoreError> {
        let page = self.session.next_page()?;
        Ok(SearchPage {
            has_more: page.has_more,
            hits: page
                .hits
                .into_iter()
                .map(|hit| SearchHit {
                    frame_id: hit.frame_id,
                    run_id: hit.run_id,
                    t_ms: hit.t_ms,
                    bundle_id: hit.bundle_id,
                    window: hit.window,
                    url: hit.url,
                    rects: hit.rects.into_iter().map(Into::into).collect(),
                    snippet: hit.snippet,
                })
                .collect(),
        })
    }

    /// Stops a query that's running, from any thread. Call this when the search text
    /// changes, so an old query doesn't hold up the new one.
    pub fn cancel(&self) {
        self.session.cancel();
    }
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
    /// The front window, as a fraction of the display.
    pub front_rect: Option<NormalizedRect>,
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
                front_rect: sample.front_rect.map(|r| {
                    [scaled(r.x), scaled(r.y), scaled(r.width), scaled(r.height)]
                }),
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

    /// Fetches frames waiting for OCR, recording the attempt.
    pub fn next_ocr_batch(
        &self,
        max: u32,
        now_ms: i64,
        include_deferred: bool,
    ) -> Result<Vec<OcrJob>, CoreError> {
        let jobs = self.engine.next_ocr_batch(OcrBatchOptions { max, now_ms, include_deferred })?;
        Ok(jobs
            .into_iter()
            .map(|job| OcrJob { frame_id: job.frame_id, t_ms: job.t_ms, attempt: job.attempt })
            .collect())
    }

    /// Stores OCR results and waits until they're committed.
    pub fn submit_ocr(&self, results: Vec<OcrResultInput>) -> Result<(), CoreError> {
        Ok(self.engine.submit_ocr(
            results
                .into_iter()
                .map(|result| OcrResult {
                    frame_id: result.frame_id,
                    lines: result
                        .lines
                        .into_iter()
                        .map(|line| OcrLine { text: line.text, rect: line.rect.into() })
                        .collect(),
                })
                .collect(),
        )?)
    }

    /// Records that OCR couldn't process a frame.
    pub fn fail_ocr(&self, frame_id: i64) -> Result<(), CoreError> {
        Ok(self.engine.fail_ocr(frame_id)?)
    }

    /// Starts a search. Returns nothing if the text has nothing searchable in it.
    pub fn search(
        &self,
        text: String,
        facets: SearchFacets,
        order: SearchOrder,
    ) -> Result<Option<Arc<SearchHandle>>, CoreError> {
        let Some(query) = Query::parse(&text) else {
            return Ok(None);
        };
        let session = self.engine.search(
            query,
            Facets {
                bundle_ids: facets.bundle_ids,
                from_ms: facets.from_ms,
                to_ms: facets.to_ms,
                starred_only: facets.starred_only,
            },
            match order {
                SearchOrder::Relevance => Order::Relevance,
                SearchOrder::Newest => Order::Newest,
            },
        )?;
        Ok(Some(Arc::new(SearchHandle { session })))
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
