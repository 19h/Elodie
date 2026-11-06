//! Reading and removing stretches of time, which is what managing recordings is built on.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use elodie_engine::{
    AppendOutcome, Engine, EngineConfig, EngineError, FrameContext, MomentQuery, OcrBatchOptions,
    OcrLine, OcrResult, Rect, Sample,
};
use elodie_vault::MasterKey;
use tempfile::TempDir;

const DISPLAY: [u8; 16] = [1; 16];
const OTHER_DISPLAY: [u8; 16] = [2; 16];
const START: i64 = 1_000_000;

fn config() -> EngineConfig {
    EngineConfig {
        batch_interval: Duration::from_millis(5),
        sample_queue: 4096,
        ..EngineConfig::default()
    }
}

fn master() -> MasterKey {
    MasterKey::from_bytes([3; 32])
}

fn open(root: &Path) -> Engine {
    Engine::open(root, master(), config()).unwrap().0
}

fn context(app: &str, window: &str) -> FrameContext {
    FrameContext {
        bundle_id: Some(app.to_owned()),
        window: Some(window.to_owned()),
        ..FrameContext::default()
    }
}

/// Frame `n` is at START + 2 s × n, and a keyframe when `n` is a multiple of `key_every`.
fn sample(n: i64, key_every: i64, display: [u8; 16], context: FrameContext) -> Sample {
    Sample {
        display_uuid: display,
        width: 100,
        height: 50,
        parameter_sets: Arc::from(&b"parameter sets"[..]),
        wall_ms: START + n * 2000,
        mono_ns: n as u64,
        is_sync: n % key_every == 0,
        context,
        data: vec![n as u8; 100],
    }
}

fn append(engine: &Engine, sample: Sample) {
    assert_eq!(engine.append(sample).unwrap(), AppendOutcome::Accepted);
}

fn settle(engine: &Engine, frames: u64) {
    for _ in 0..1000 {
        if engine.stats().indexed_frames >= frames {
            return;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    panic!("only {} of {frames} frames were indexed", engine.stats().indexed_frames);
}

fn frame_count(engine: &Engine) -> i64 {
    engine.open_reader().unwrap().query_row("SELECT count(*) FROM frame", [], |r| r.get(0)).unwrap()
}

/// Thirty frames in one app, then thirty in another, with a keyframe every ten.
fn two_apps(engine: &Engine) -> u64 {
    for n in 0..30 {
        append(engine, sample(n, 10, DISPLAY, context("com.example.one", "First")));
    }
    for n in 30..60 {
        append(engine, sample(n, 10, DISPLAY, context("com.example.two", "Second")));
    }
    engine.seal_all().unwrap();
    settle(engine, 60);
    60
}

#[test]
fn a_second_process_cant_open_the_same_vault() {
    let dir = TempDir::new().unwrap();
    let first = open(dir.path());
    match Engine::open(dir.path(), master(), config()) {
        Err(EngineError::VaultBusy) => {}
        Err(other) => panic!("expected the vault to be busy, got {other}"),
        Ok(_) => panic!("two engines opened one vault"),
    }
    drop(first);
    // It's free again once the first has gone.
    drop(open(dir.path()));
}

#[test]
fn frame_ids_are_never_reused_after_deleting_the_newest() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    two_apps(&engine);
    let newest = engine.lookup(&DISPLAY, START + 59 * 2000).unwrap().unwrap().id;

    engine.delete_range(START + 40 * 2000, START + 59 * 2000).unwrap();
    assert!(engine.lookup(&DISPLAY, i64::MAX).unwrap().unwrap().id < newest);

    append(&engine, sample(60, 10, DISPLAY, context("com.example.two", "Second")));
    engine.seal_all().unwrap();
    for _ in 0..1000 {
        if engine.lookup(&DISPLAY, i64::MAX).unwrap().unwrap().t_ms == START + 60 * 2000 {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    let added = engine.lookup(&DISPLAY, i64::MAX).unwrap().unwrap();
    assert_eq!(added.t_ms, START + 60 * 2000);
    assert!(added.id > newest, "new frame {} reused an ID up to {newest}", added.id);
}

#[test]
fn removing_the_middle_of_a_run_leaves_two_runs_with_a_real_gap() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    for n in 0..60 {
        append(&engine, sample(n, 10, DISPLAY, context("com.example.one", "Only")));
    }
    engine.seal_all().unwrap();
    settle(&engine, 60);
    let before = engine.timeline(&DISPLAY, START, START + 120_000, 0).unwrap();
    assert_eq!(before.runs.len(), 1);

    engine.delete_range(START + 20 * 2000, START + 29 * 2000).unwrap();

    let after = engine.timeline(&DISPLAY, START, START + 120_000, 0).unwrap();
    assert_eq!(after.runs.len(), 2, "{:?}", after.runs);
    assert!(after.runs[0].end_ms < START + 20 * 2000);
    assert!(after.runs[1].start_ms > START + 29 * 2000);
}

#[test]
fn a_cut_on_a_keyframe_takes_nothing_extra() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    two_apps(&engine);
    // Frames 20 to 29, and frame 30 starts a new group.
    let summary = engine.slice_summary(START + 20 * 2000, START + 29 * 2000).unwrap();
    assert_eq!(summary.frames, 10);
    assert_eq!(summary.dependent_frames, 0);
    assert_eq!(engine.delete_range(START + 20 * 2000, START + 29 * 2000).unwrap(), 10);
    assert_eq!(frame_count(&engine), 50);
}

#[test]
fn a_cut_midway_through_a_group_says_what_else_goes() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    two_apps(&engine);
    // Ends at frame 25, so 26 to 29 depend on it, until the keyframe at 30.
    let summary = engine.slice_summary(START + 20 * 2000, START + 25 * 2000).unwrap();
    assert_eq!(summary.frames, 6);
    assert_eq!(summary.dependent_frames, 4);
    assert_eq!(summary.dependent_until_ms, Some(START + 29 * 2000));
    assert_eq!(engine.delete_range(START + 20 * 2000, START + 25 * 2000).unwrap(), 10);
}

#[test]
fn a_summary_counts_what_a_stretch_holds() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    two_apps(&engine);
    let starred = engine.lookup(&DISPLAY, START + 30 * 2000).unwrap().unwrap();
    engine.set_starred(starred.id, true).unwrap();

    let summary = engine.slice_summary(START + 20 * 2000, START + 39 * 2000).unwrap();
    assert_eq!(summary.frames, 20);
    // Stored frames carry encryption overhead and their context as well as the picture.
    assert!(summary.bytes >= 20 * 100);
    assert_eq!(summary.starred, 1);
    let apps: Vec<_> = summary.apps.iter().map(|(app, _)| app.clone().unwrap()).collect();
    assert_eq!(apps.len(), 2);
    assert!(apps.contains(&"com.example.one".to_owned()));
    assert!(summary.windows.contains(&"Second".to_owned()));
}

#[test]
fn stars_can_be_read_back() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    two_apps(&engine);
    let frame = engine.lookup(&DISPLAY, START + 10 * 2000).unwrap().unwrap();
    assert!(!engine.is_starred(frame.id).unwrap());

    engine.set_starred(frame.id, true).unwrap();
    assert!(engine.is_starred(frame.id).unwrap());
    let stars = engine.stars(&DISPLAY, START, START + 120_000).unwrap();
    assert_eq!(stars.len(), 1);
    assert_eq!(stars[0].frame_id, frame.id);
    assert!(engine.stars(&OTHER_DISPLAY, START, START + 120_000).unwrap().is_empty());

    engine.set_starred(frame.id, false).unwrap();
    assert!(!engine.is_starred(frame.id).unwrap());
}

#[test]
fn moments_can_be_listed_without_searching() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    two_apps(&engine);
    let frame = engine.lookup(&DISPLAY, START + 10 * 2000).unwrap().unwrap();
    engine.set_starred(frame.id, true).unwrap();

    let starred = engine
        .moments(&MomentQuery { starred_only: true, limit: 10, ..MomentQuery::default() })
        .unwrap();
    assert_eq!(starred.len(), 1);
    assert_eq!(starred[0].frame_id, frame.id);
    assert_eq!(starred[0].display_uuid, Some(DISPLAY));
    assert_eq!(starred[0].bundle_id.as_deref(), Some("com.example.one"));

    let from_app = engine
        .moments(&MomentQuery {
            bundle_ids: vec!["com.example.two".to_owned()],
            limit: 10,
            ..MomentQuery::default()
        })
        .unwrap();
    assert_eq!(from_app.len(), 1, "one stretch gives one result");
    assert_eq!(from_app[0].t_ms, START + 59 * 2000);

    let none_yet = engine
        .moments(&MomentQuery { transcripts_only: true, limit: 10, ..MomentQuery::default() })
        .unwrap();
    assert!(none_yet.is_empty());
}

#[test]
fn displays_report_what_they_recorded() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    append(&engine, sample(0, 1, DISPLAY, context("com.example.one", "First")));
    append(&engine, sample(5, 1, OTHER_DISPLAY, context("com.example.two", "Second")));
    engine.seal_all().unwrap();
    settle(&engine, 2);

    let displays = engine.displays().unwrap();
    assert_eq!(displays.len(), 2);
    assert_eq!(displays[0].uuid, OTHER_DISPLAY, "the most recently used comes first");
    assert_eq!(displays[0].first_ms, START + 10_000);
    assert_eq!(displays[1].uuid, DISPLAY);
    assert_eq!(displays[1].width, 100);
}

#[test]
fn a_moment_knows_what_was_in_front() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    two_apps(&engine);
    let segment = engine.segment_at(&DISPLAY, START + 40 * 2000).unwrap().unwrap();
    assert_eq!(segment.bundle_id.as_deref(), Some("com.example.two"));
    assert_eq!(segment.window.as_deref(), Some("Second"));
}

#[test]
fn space_is_reported_by_app() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    for n in 0..30 {
        append(&engine, sample(n, 10, DISPLAY, context("com.example.one", "First")));
    }
    for n in 30..40 {
        append(&engine, sample(n, 10, DISPLAY, context("com.example.two", "Second")));
    }
    engine.seal_all().unwrap();
    settle(&engine, 40);
    let apps = engine.storage_by_app().unwrap();
    assert_eq!(apps[0].bundle_id.as_deref(), Some("com.example.one"));
    assert_eq!(apps[0].frames, 30);
    assert!(apps[0].bytes >= 3000 && apps[0].bytes > apps[1].bytes);
    assert_eq!(apps[1].frames, 10);
    let stretches = engine.app_stretches("com.example.two").unwrap();
    assert_eq!(stretches.len(), 1);
}

#[test]
fn deleting_everything_gives_the_space_back() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    let frames = 400;
    for n in 0..frames {
        append(&engine, sample(n, 10, DISPLAY, context("com.example.one", &format!("Window {n}"))));
    }
    engine.seal_all().unwrap();
    settle(&engine, frames as u64);
    let jobs = engine
        .next_ocr_batch(OcrBatchOptions { max: 200, now_ms: START, include_deferred: true })
        .unwrap();
    let results = jobs
        .iter()
        .map(|job| OcrResult {
            frame_id: job.frame_id,
            lines: vec![OcrLine {
                text: "a long line of text to take up some room in the database".repeat(20),
                rect: Rect { x: 0.1, y: 0.1, width: 0.5, height: 0.02 },
            }],
        })
        .collect();
    engine.submit_ocr(results).unwrap();

    let database = dir.path().join("vault.db");
    let wal = dir.path().join("vault.db-wal");
    let size = |path: &Path| std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let before = size(&database) + size(&wal);

    engine.delete_range(i64::MIN / 2, i64::MAX / 2).unwrap();

    let after = size(&database) + size(&wal);
    assert_eq!(frame_count(&engine), 0);
    assert!(after < before, "the database stayed at {after} bytes, down from {before}");
}

/// A request that can never succeed mustn't stop everything else from being stored.
#[test]
fn a_delete_that_cant_finish_fails_and_recording_carries_on() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    two_apps(&engine);
    // Rewriting needs the old chunk's file, so losing it makes this deletion impossible.
    for entry in walk(&dir.path().join("chunks")) {
        std::fs::remove_file(entry).unwrap();
    }
    let outcome = engine.delete_range(START + 22 * 2000, START + 25 * 2000);
    assert!(outcome.is_err(), "the deletion should have reported failing");

    append(&engine, sample(60, 10, DISPLAY, context("com.example.two", "Second")));
    engine.seal_all().unwrap();
    settle(&engine, 61);
}

fn walk(directory: &Path) -> Vec<std::path::PathBuf> {
    let mut files = Vec::new();
    for entry in std::fs::read_dir(directory).unwrap().flatten() {
        if entry.path().is_dir() {
            files.extend(walk(&entry.path()));
        } else {
            files.push(entry.path());
        }
    }
    files
}
