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
    #[error("this vault is already open in another process")]
    VaultBusy,
    #[error("storage failed: {message}")]
    Storage { message: String },
}

impl From<EngineError> for CoreError {
    fn from(error: EngineError) -> Self {
        match error {
            EngineError::Stopped => CoreError::Stopped,
            EngineError::VaultBusy => CoreError::VaultBusy,
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

/// A line of text in a frame.
#[derive(Debug, uniffi::Record)]
pub struct RecordedDisplayInfo {
    pub uuid: Vec<u8>,
    pub width: i64,
    pub height: i64,
    pub first_ms: i64,
    pub last_ms: i64,
}

/// A starred frame.
#[derive(Debug, uniffi::Record)]
pub struct StarredFrameInfo {
    pub frame_id: i64,
    pub t_ms: i64,
}

/// What was in front at a moment.
#[derive(Debug, uniffi::Record)]
pub struct SegmentDetails {
    pub bundle_id: Option<String>,
    pub window: Option<String>,
    pub url: Option<String>,
    pub t_start_ms: i64,
    pub t_end_ms: i64,
}

/// Time spent in an app within a stretch.
#[derive(Debug, uniffi::Record)]
pub struct SliceApp {
    pub bundle_id: Option<String>,
    pub duration_ms: i64,
}

/// What a stretch of time holds.
#[derive(Debug, uniffi::Record)]
pub struct SliceSummaryInfo {
    pub frames: i64,
    pub bytes: i64,
    pub starred: i64,
    pub transcript_lines: i64,
    pub apps: Vec<SliceApp>,
    pub windows: Vec<String>,
    pub dependent_frames: i64,
    pub dependent_until_ms: Option<i64>,
}

/// A stretch of speech.
#[derive(Debug, uniffi::Record)]
pub struct TranscriptSessionInfo {
    pub title: Option<String>,
    pub t_start_ms: i64,
    pub t_end_ms: i64,
    pub lines: i64,
}

/// Recording space used by an app.
#[derive(Debug, uniffi::Record)]
pub struct AppStorageInfo {
    pub bundle_id: Option<String>,
    pub bytes: i64,
    pub frames: i64,
}

/// A stretch of an app's recording.
#[derive(Debug, uniffi::Record)]
pub struct Stretch {
    pub t_start_ms: i64,
    pub t_end_ms: i64,
}

/// What to list without searching for words.
#[derive(Debug, uniffi::Record)]
pub struct MomentQuery {
    pub bundle_ids: Vec<String>,
    pub starred_only: bool,
    pub transcripts_only: bool,
    pub before_ms: Option<i64>,
    pub limit: u32,
}

#[derive(Debug, uniffi::Record)]
pub struct FrameLineInfo {
    pub text: String,
    pub rect: NormalizedRect,
}

/// A meeting that was transcribed.
#[derive(Debug, uniffi::Record)]
pub struct MeetingInfo {
    pub title: Option<String>,
    pub t_start_ms: i64,
    pub t_end_ms: Option<i64>,
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
    pub transcripts_only: bool,
}

/// A moment that matched a search.
#[derive(Debug, uniffi::Record)]
pub struct SearchHit {
    pub frame_id: i64,
    pub run_id: i64,
    pub t_ms: i64,
    pub display_uuid: Option<Vec<u8>>,
    pub bundle_id: Option<String>,
    pub window: Option<String>,
    pub url: Option<String>,
    pub rects: Vec<NormalizedRect>,
    pub snippet: String,
    pub is_transcript: bool,
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
                    display_uuid: hit.display_uuid.map(|uuid| uuid.to_vec()),
                    bundle_id: hit.bundle_id,
                    window: hit.window,
                    url: hit.url,
                    rects: hit.rects.into_iter().map(Into::into).collect(),
                    snippet: hit.snippet,
                    is_transcript: hit.is_transcript,
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

/// A stretch of time in one app, indexing into `TimelineData::apps`.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct TimelineRun {
    pub start_ms: i64,
    pub end_ms: i64,
    pub app: u32,
}

/// Runs for part of the timeline.
#[derive(Debug, uniffi::Record)]
pub struct TimelineData {
    pub apps: Vec<Option<String>>,
    pub runs: Vec<TimelineRun>,
}

/// A transcribed word.
#[derive(Debug, uniffi::Record)]
pub struct SpokenWordInput {
    pub text: String,
    pub t_ms: i64,
    pub duration_ms: i64,
    pub confidence: f32,
    pub is_me: bool,
}

/// A line of a transcript.
#[derive(Debug, uniffi::Record)]
pub struct TranscriptLineInfo {
    pub text: String,
    pub t_ms: i64,
    pub duration_ms: i64,
    pub is_me: bool,
}

/// What was on screen for a frame.
#[derive(Debug, uniffi::Record)]
pub struct FrameInfo {
    pub bundle_id: Option<String>,
    pub window: Option<String>,
    pub url: Option<String>,
}

/// Time spent in one app.
#[derive(Debug, uniffi::Record)]
pub struct AppTimeInfo {
    pub bundle_id: Option<String>,
    pub milliseconds: i64,
}

/// A long stretch of focus.
#[derive(Debug, uniffi::Record)]
pub struct ActivityBlockInfo {
    pub start_ms: i64,
    pub end_ms: i64,
    pub bundle_id: Option<String>,
    pub window: Option<String>,
    pub url: Option<String>,
}

/// A summary of what was recorded in a period.
#[derive(Debug, uniffi::Record)]
pub struct RecapInfo {
    pub total_active_ms: i64,
    pub apps: Vec<AppTimeInfo>,
    pub activity: Vec<i64>,
    pub blocks: Vec<ActivityBlockInfo>,
}

/// A span of time to ask about.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct Period {
    pub from_ms: i64,
    pub to_ms: i64,
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

fn gop_from(gop: remind_engine::Gop) -> Gop {
    Gop {
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
    }
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
        Ok(gop_from(self.engine.read_gop(frame_id)?))
    }

    /// Reads only the keyframe of a frame's group.
    pub fn read_keyframe(&self, frame_id: i64) -> Result<Gop, CoreError> {
        Ok(gop_from(self.engine.read_keyframe(frame_id)?))
    }

    /// The next frame on the same display, going forward or back.
    pub fn neighbour(&self, frame_id: i64, forward: bool) -> Result<Option<FrameRef>, CoreError> {
        let frame = self.engine.neighbour(frame_id, forward)?;
        Ok(frame.map(|f| FrameRef { id: f.id, t_ms: f.t_ms }))
    }

    /// Runs for part of the timeline. Anything shorter than `min_duration_ms` is
    /// merged, so pass the time one pixel covers at the current zoom.
    pub fn timeline(
        &self,
        display_uuid: Vec<u8>,
        from_ms: i64,
        to_ms: i64,
        min_duration_ms: i64,
    ) -> Result<TimelineData, CoreError> {
        let timeline =
            self.engine.timeline(&display_id(&display_uuid)?, from_ms, to_ms, min_duration_ms)?;
        Ok(TimelineData {
            apps: timeline.apps,
            runs: timeline
                .runs
                .into_iter()
                .map(|r| TimelineRun { start_ms: r.start_ms, end_ms: r.end_ms, app: r.app })
                .collect(),
        })
    }

    /// The stretches with something recorded for a display, oldest first. Stretches closer
    /// together than `min_gap_ms` count as one.
    pub fn recorded_periods(&self, display_uuid: Vec<u8>, min_gap_ms: i64) -> Result<Vec<Period>, CoreError> {
        let periods = self.engine.recorded_periods(&display_id(&display_uuid)?, min_gap_ms)?;
        Ok(periods.into_iter().map(|(from_ms, to_ms)| Period { from_ms, to_ms }).collect())
    }

    /// What was on screen for a frame.
    pub fn frame_context(&self, frame_id: i64) -> Result<Option<FrameInfo>, CoreError> {
        Ok(self.engine.frame_context(frame_id)?.map(|context| FrameInfo {
            bundle_id: context.bundle_id,
            window: context.window,
            url: context.url,
        }))
    }

    /// Summarises what was recorded in a period.
    pub fn recap(&self, from_ms: i64, to_ms: i64, bucket_ms: i64) -> Result<RecapInfo, CoreError> {
        let recap = self.engine.recap(from_ms, to_ms, bucket_ms)?;
        Ok(RecapInfo {
            total_active_ms: recap.total_active_ms,
            activity: recap.activity,
            apps: recap
                .apps
                .into_iter()
                .map(|app| AppTimeInfo { bundle_id: app.bundle_id, milliseconds: app.milliseconds })
                .collect(),
            blocks: recap
                .blocks
                .into_iter()
                .map(|block| ActivityBlockInfo {
                    start_ms: block.start_ms,
                    end_ms: block.end_ms,
                    bundle_id: block.bundle_id,
                    window: block.window,
                    url: block.url,
                })
                .collect(),
        })
    }

    /// Stores transcribed words, dropping any that were only the speakers' echo.
    pub fn append_transcript(
        &self,
        words: Vec<SpokenWordInput>,
        title: Option<String>,
    ) -> Result<(), CoreError> {
        Ok(self.engine.append_transcript(
            words
                .into_iter()
                .map(|word| remind_engine::SpokenWord {
                    text: word.text,
                    t_ms: word.t_ms,
                    duration_ms: word.duration_ms,
                    confidence: word.confidence,
                    is_me: word.is_me,
                })
                .collect(),
            title,
        )?)
    }

    /// What was said in a period.
    pub fn transcript(&self, from_ms: i64, to_ms: i64) -> Result<Vec<TranscriptLineInfo>, CoreError> {
        Ok(self
            .engine
            .transcript(from_ms, to_ms)?
            .into_iter()
            .map(|line| TranscriptLineInfo {
                text: line.text,
                t_ms: line.t_ms,
                duration_ms: line.duration_ms,
                is_me: line.is_me,
            })
            .collect())
    }

    /// The text a frame shows, front window first.
    pub fn frame_text(&self, frame_id: i64) -> Result<Vec<String>, CoreError> {
        Ok(self.engine.frame_text(frame_id)?)
    }

    /// The lines of text a frame shows and where they are.
    pub fn frame_lines(&self, frame_id: i64) -> Result<Vec<FrameLineInfo>, CoreError> {
        Ok(self
            .engine
            .frame_lines(frame_id)?
            .into_iter()
            .map(|line| FrameLineInfo { text: line.text, rect: line.rect.into() })
            .collect())
    }

    /// Every display with recordings, most recently used first.
    pub fn displays(&self) -> Result<Vec<RecordedDisplayInfo>, CoreError> {
        Ok(self
            .engine
            .displays()?
            .into_iter()
            .map(|display| RecordedDisplayInfo {
                uuid: display.uuid.to_vec(),
                width: display.width,
                height: display.height,
                first_ms: display.first_ms,
                last_ms: display.last_ms,
            })
            .collect())
    }

    /// Whether a frame is starred.
    pub fn is_starred(&self, frame_id: i64) -> Result<bool, CoreError> {
        Ok(self.engine.is_starred(frame_id)?)
    }

    /// Starred frames on a display in a period, earliest first.
    pub fn stars(
        &self,
        display: Vec<u8>,
        from_ms: i64,
        to_ms: i64,
    ) -> Result<Vec<StarredFrameInfo>, CoreError> {
        Ok(self
            .engine
            .stars(&display_id(&display)?, from_ms, to_ms)?
            .into_iter()
            .map(|star| StarredFrameInfo { frame_id: star.frame_id, t_ms: star.t_ms })
            .collect())
    }

    /// What was in front on a display at a moment.
    pub fn segment_at(&self, display: Vec<u8>, t_ms: i64) -> Result<Option<SegmentDetails>, CoreError> {
        Ok(self.engine.segment_at(&display_id(&display)?, t_ms)?.map(|segment| SegmentDetails {
            bundle_id: segment.bundle_id,
            window: segment.window,
            url: segment.url,
            t_start_ms: segment.t_start,
            t_end_ms: segment.t_end,
        }))
    }

    /// What a stretch of time holds.
    pub fn slice_summary(&self, from_ms: i64, to_ms: i64) -> Result<SliceSummaryInfo, CoreError> {
        let summary = self.engine.slice_summary(from_ms, to_ms)?;
        Ok(SliceSummaryInfo {
            frames: summary.frames,
            bytes: summary.bytes,
            starred: summary.starred,
            transcript_lines: summary.transcript_lines,
            apps: summary
                .apps
                .into_iter()
                .map(|(bundle_id, duration_ms)| SliceApp { bundle_id, duration_ms })
                .collect(),
            windows: summary.windows,
            dependent_frames: summary.dependent_frames,
            dependent_until_ms: summary.dependent_until_ms,
        })
    }

    /// Stretches of speech that overlap a period, most recent first.
    pub fn transcript_sessions(
        &self,
        from_ms: i64,
        to_ms: i64,
        limit: u32,
    ) -> Result<Vec<TranscriptSessionInfo>, CoreError> {
        Ok(self
            .engine
            .transcript_sessions(from_ms, to_ms, limit)?
            .into_iter()
            .map(|session| TranscriptSessionInfo {
                title: session.title,
                t_start_ms: session.t_start,
                t_end_ms: session.t_end,
                lines: session.lines,
            })
            .collect())
    }

    /// How much recording space each app uses, most first.
    pub fn storage_by_app(&self) -> Result<Vec<AppStorageInfo>, CoreError> {
        Ok(self
            .engine
            .storage_by_app()?
            .into_iter()
            .map(|app| AppStorageInfo { bundle_id: app.bundle_id, bytes: app.bytes, frames: app.frames })
            .collect())
    }

    /// The stretches of time an app was recorded in.
    pub fn app_stretches(&self, bundle_id: String) -> Result<Vec<Stretch>, CoreError> {
        Ok(self
            .engine
            .app_stretches(&bundle_id)?
            .into_iter()
            .map(|(t_start_ms, t_end_ms)| Stretch { t_start_ms, t_end_ms })
            .collect())
    }

    /// Lists moments without searching for any words.
    pub fn moments(&self, query: MomentQuery) -> Result<Vec<SearchHit>, CoreError> {
        Ok(self
            .engine
            .moments(&remind_engine::MomentQuery {
                bundle_ids: query.bundle_ids,
                starred_only: query.starred_only,
                transcripts_only: query.transcripts_only,
                before_ms: query.before_ms,
                limit: query.limit,
            })?
            .into_iter()
            .map(|moment| SearchHit {
                frame_id: moment.frame_id,
                run_id: moment.run_id,
                t_ms: moment.t_ms,
                display_uuid: moment.display_uuid.map(|uuid| uuid.to_vec()),
                bundle_id: moment.bundle_id,
                window: moment.window,
                url: moment.url,
                rects: Vec::new(),
                snippet: moment.snippet,
                is_transcript: moment.is_transcript,
            })
            .collect())
    }

    /// Notes a meeting that was transcribed.
    pub fn record_meeting(&self, title: Option<String>, t_start_ms: i64, t_end_ms: i64) -> Result<(), CoreError> {
        Ok(self.engine.record_meeting(title, t_start_ms, t_end_ms)?)
    }

    /// Meetings that started in a period, earliest first.
    pub fn meetings(&self, from_ms: i64, to_ms: i64) -> Result<Vec<MeetingInfo>, CoreError> {
        Ok(self
            .engine
            .meetings(from_ms, to_ms)?
            .into_iter()
            .map(|meeting| MeetingInfo {
                title: meeting.title,
                t_start_ms: meeting.t_start,
                t_end_ms: meeting.t_end,
            })
            .collect())
    }

    /// Every app that has been recorded, most recent first.
    pub fn recorded_apps(&self) -> Result<Vec<String>, CoreError> {
        Ok(self.engine.recorded_apps()?)
    }

    /// Permanently deletes frames from `from_ms` through `to_ms`, and their text.
    /// Returns how many frames were removed. This can take a while.
    pub fn delete_range(&self, from_ms: i64, to_ms: i64) -> Result<u64, CoreError> {
        Ok(self.engine.delete_range(from_ms, to_ms)?)
    }

    /// Stars or unstars a frame.
    pub fn set_starred(&self, frame_id: i64, starred: bool) -> Result<(), CoreError> {
        Ok(self.engine.set_starred(frame_id, starred)?)
    }

    /// Which of the given periods have any recording.
    pub fn active_periods(&self, periods: Vec<Period>) -> Result<Vec<bool>, CoreError> {
        let spans: Vec<(i64, i64)> = periods.iter().map(|p| (p.from_ms, p.to_ms)).collect();
        Ok(self.engine.active_periods(&spans)?)
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
                transcripts_only: facets.transcripts_only,
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
