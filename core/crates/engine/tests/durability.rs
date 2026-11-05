//! The engine's behaviour within one process. `tools/torture` covers real kills.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use remind_engine::{AppendOutcome, Engine, EngineConfig, FrameContext, Sample};
use remind_vault::MasterKey;
use tempfile::TempDir;

const DISPLAY: [u8; 16] = [1; 16];

/// Tests append far faster than real capture, so the queue is large enough that
/// nothing gets dropped unless a test asks for that.
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

fn params() -> Arc<[u8]> {
    Arc::from(&b"parameter sets"[..])
}

fn sample(n: u64, is_sync: bool) -> Sample {
    Sample {
        display_uuid: DISPLAY,
        width: 100,
        height: 50,
        parameter_sets: params(),
        wall_ms: 1_000_000 + n as i64 * 2000,
        mono_ns: n,
        is_sync,
        context: FrameContext {
            bundle_id: Some("com.example".to_owned()),
            ..FrameContext::default()
        },
        data: vec![n as u8; 100],
    }
}

fn wait_for(engine: &Engine, frames: u64) {
    for _ in 0..500 {
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

fn scalar(engine: &Engine, sql: &str) -> i64 {
    engine.open_reader().unwrap().query_row(sql, [], |r| r.get(0)).unwrap()
}

fn chunk_files(root: &Path) -> Vec<std::path::PathBuf> {
    let mut files = Vec::new();
    for shard in std::fs::read_dir(root.join("chunks")).unwrap() {
        for entry in std::fs::read_dir(shard.unwrap().path()).unwrap() {
            files.push(entry.unwrap().path());
        }
    }
    files
}

#[test]
fn appended_frames_become_readable() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    for n in 0..5 {
        assert_eq!(engine.append(sample(n, n == 0)).unwrap(), AppendOutcome::Accepted);
    }
    wait_for(&engine, 5);

    let frame = engine.lookup(&DISPLAY, 1_000_000 + 3 * 2000 + 1).unwrap().unwrap();
    assert_eq!(frame.t_ms, 1_000_000 + 3 * 2000);

    let gop = engine.read_gop(frame.id).unwrap();
    assert_eq!(gop.samples.len(), 5);
    assert_eq!(gop.target, 3);
    assert_eq!(gop.samples[3].data, vec![3; 100]);
    assert_eq!(gop.parameter_sets, b"parameter sets");
    assert!(gop.samples[0].is_sync);
    assert!(!gop.samples[1].is_sync);
    engine.close().unwrap();
}

#[test]
fn a_gop_ends_at_the_next_keyframe() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    for n in 0..6 {
        engine.append(sample(n, n % 3 == 0)).unwrap();
    }
    wait_for(&engine, 6);
    let frame = engine.lookup(&DISPLAY, 1_000_000 + 4 * 2000).unwrap().unwrap();
    let gop = engine.read_gop(frame.id).unwrap();
    assert_eq!(gop.samples.iter().map(|s| s.mono_ns).collect::<Vec<_>>(), [3, 4, 5]);
    assert_eq!(gop.target, 1);
    engine.close().unwrap();
}

#[test]
fn the_first_sample_must_be_a_keyframe() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    assert_eq!(engine.append(sample(0, false)).unwrap(), AppendOutcome::NeedsKeyframe);
    assert_eq!(engine.append(sample(1, false)).unwrap(), AppendOutcome::NeedsKeyframe);
    assert_eq!(engine.append(sample(2, true)).unwrap(), AppendOutcome::Accepted);
    assert_eq!(engine.append(sample(3, false)).unwrap(), AppendOutcome::Accepted);
    engine.close().unwrap();
}

#[test]
fn new_parameter_sets_require_a_keyframe_and_a_new_chunk() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    engine.append(sample(0, true)).unwrap();
    let mut changed = sample(1, false);
    changed.parameter_sets = Arc::from(&b"different"[..]);
    assert_eq!(engine.append(changed.clone()).unwrap(), AppendOutcome::NeedsKeyframe);
    changed.is_sync = true;
    assert_eq!(engine.append(changed).unwrap(), AppendOutcome::Accepted);
    wait_for(&engine, 2);
    engine.seal_all().unwrap();
    assert_eq!(chunk_files(dir.path()).len(), 2);
    engine.close().unwrap();
}

#[test]
fn a_full_queue_drops_and_then_demands_a_keyframe() {
    let dir = TempDir::new().unwrap();
    let (engine, _) = Engine::open(dir.path(), master(), EngineConfig::default()).unwrap();
    // Flood the queue until something is dropped. The appender may keep up for
    // a while, so this keeps going.
    let mut next = 0;
    let mut outcome = AppendOutcome::Accepted;
    while outcome == AppendOutcome::Accepted && next < 1_000_000 {
        let mut s = sample(next, next == 0);
        s.data = vec![0; 64 * 1024];
        outcome = engine.append(s).unwrap();
        next += 1;
    }
    assert_eq!(outcome, AppendOutcome::DroppedQueueFull);
    assert_eq!(engine.append(sample(next, false)).unwrap(), AppendOutcome::NeedsKeyframe);
    assert!(engine.stats().dropped_frames >= 2);
    engine.close().unwrap();
}

#[test]
fn sealing_demands_a_keyframe_next() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    engine.append(sample(0, true)).unwrap();
    engine.seal_all().unwrap();
    assert_eq!(engine.append(sample(1, false)).unwrap(), AppendOutcome::NeedsKeyframe);
    assert_eq!(engine.append(sample(2, true)).unwrap(), AppendOutcome::Accepted);
    engine.close().unwrap();
}

/// P-frames already queued when a chunk goes away must not start a new chunk,
/// because it could never be decoded. The full-disk torture test found this.
#[test]
fn queued_frames_never_start_a_chunk_without_a_keyframe() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    // Interleave seals with appends, so P-frames are often queued across a seal.
    for n in 0..200u64 {
        engine.append(sample(n, n % 7 == 0)).unwrap();
        if n % 5 == 0 {
            engine.seal_all().unwrap();
        }
    }
    engine.close().unwrap();

    let (engine, _) = Engine::open(dir.path(), master(), config()).unwrap();
    let conn = engine.open_reader().unwrap();
    let bad: i64 = conn
        .query_row("SELECT count(*) FROM frame WHERE seq = 0 AND is_sync = 0", [], |r| r.get(0))
        .unwrap();
    assert_eq!(bad, 0, "{bad} chunks start without a keyframe");
    engine.close().unwrap();
}

#[test]
fn closing_seals_chunks_and_commits_everything() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    for n in 0..10 {
        engine.append(sample(n, n == 0)).unwrap();
    }
    engine.close().unwrap();

    let (engine, report) = Engine::open(dir.path(), master(), config()).unwrap();
    assert_eq!(frame_count(&engine), 10);
    assert_eq!(report.chunks_checked, 0, "a clean shutdown leaves nothing to recover");
    assert_eq!(report.frames_replayed, 0);
    engine.close().unwrap();
}

#[test]
fn chunks_rotate_only_on_keyframes() {
    let dir = TempDir::new().unwrap();
    let small = EngineConfig { chunk_max_bytes: 1, ..config() };
    let (engine, _) = Engine::open(dir.path(), master(), small).unwrap();
    for n in 0..9 {
        engine.append(sample(n, n % 3 == 0)).unwrap();
    }
    engine.close().unwrap();
    assert_eq!(chunk_files(dir.path()).len(), 3);
}

/// Recovery with a database that never heard about the chunks.
#[test]
fn the_whole_database_can_be_rebuilt_from_the_log() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    for n in 0..20 {
        engine.append(sample(n, n % 5 == 0)).unwrap();
    }
    engine.close().unwrap();

    for name in ["vault.db", "vault.db-wal", "vault.db-shm"] {
        let _ = std::fs::remove_file(dir.path().join(name));
    }

    let (engine, report) = Engine::open(dir.path(), master(), config()).unwrap();
    assert_eq!(report.frames_replayed, 20);
    assert_eq!(frame_count(&engine), 20);
    assert_eq!(scalar(&engine, "SELECT count(*) FROM segment"), 1);
    assert_eq!(scalar(&engine, "SELECT count(*) FROM chunk WHERE sealed = 0"), 0);
    engine.close().unwrap();
}

/// Rewinds a chunk as a power cut could, after the database committed.
#[test]
fn rows_past_the_end_of_a_damaged_log_are_removed() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    for n in 0..10 {
        engine.append(sample(n, n == 0)).unwrap();
    }
    wait_for(&engine, 10);
    let (seq5_offset, path): (i64, String) = engine
        .open_reader()
        .unwrap()
        .query_row(
            "SELECT f.offset, c.path FROM frame f JOIN chunk c ON c.id = f.chunk_id WHERE f.seq = 5",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    engine.close().unwrap();

    // Make the chunk look unsealed again, as it would be after a real power cut.
    {
        let conn = remind_store::open_writer(
            &dir.path().join("vault.db"),
            &remind_store::DbKey(master().database_key()),
        )
        .unwrap();
        conn.execute_batch("UPDATE chunk SET sealed = 0").unwrap();
    }
    let chunk = dir.path().join(&path);
    let file = std::fs::OpenOptions::new().write(true).open(&chunk).unwrap();
    file.set_len(seq5_offset as u64 + 3).unwrap();
    drop(file);

    let (engine, report) = Engine::open(dir.path(), master(), config()).unwrap();
    assert_eq!(report.frames_removed, 5);
    assert_eq!(report.chunks_trimmed, 1);
    assert_eq!(frame_count(&engine), 5);
    assert_eq!(std::fs::metadata(&chunk).unwrap().len(), seq5_offset as u64);

    let last = engine.lookup(&DISPLAY, i64::MAX).unwrap().unwrap();
    assert_eq!(engine.read_gop(last.id).unwrap().samples.len(), 5);
    engine.close().unwrap();
}

#[test]
fn a_file_cut_off_inside_its_header_is_removed() {
    let dir = TempDir::new().unwrap();
    let shard = dir.path().join("chunks/aa");
    std::fs::create_dir_all(&shard).unwrap();
    let torn = shard.join("aabb.chunk");
    std::fs::write(&torn, b"RMDCH").unwrap();

    let (engine, report) = Engine::open(dir.path(), master(), config()).unwrap();
    assert_eq!(report.chunks_removed, 1);
    assert!(!torn.exists());
    engine.close().unwrap();
}

/// Makes every chunk look unsealed, as they would be after a real power cut.
fn mark_unsealed(root: &Path) {
    let conn = remind_store::open_writer(
        &root.join("vault.db"),
        &remind_store::DbKey(master().database_key()),
    )
    .unwrap();
    conn.execute_batch("UPDATE chunk SET sealed = 0").unwrap();
}

#[test]
fn rows_for_a_vanished_chunk_are_removed() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    for n in 0..4 {
        engine.append(sample(n, n == 0)).unwrap();
    }
    engine.close().unwrap();
    mark_unsealed(dir.path());
    std::fs::remove_file(&chunk_files(dir.path())[0]).unwrap();

    let (engine, report) = Engine::open(dir.path(), master(), config()).unwrap();
    assert_eq!(report.frames_removed, 4);
    assert_eq!(frame_count(&engine), 0);
    assert_eq!(scalar(&engine, "SELECT count(*) FROM chunk"), 0);
    assert_eq!(scalar(&engine, "SELECT count(*) FROM segment"), 0);
    engine.close().unwrap();
}

#[test]
fn rows_for_a_chunk_cut_inside_its_header_are_removed() {
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    for n in 0..4 {
        engine.append(sample(n, n == 0)).unwrap();
    }
    engine.close().unwrap();
    mark_unsealed(dir.path());
    let chunk = chunk_files(dir.path()).remove(0);
    std::fs::OpenOptions::new().write(true).open(&chunk).unwrap().set_len(10).unwrap();

    let (engine, report) = Engine::open(dir.path(), master(), config()).unwrap();
    assert_eq!(report.frames_removed, 4);
    assert_eq!(frame_count(&engine), 0);
    assert!(!chunk.exists());
    engine.close().unwrap();
}

#[test]
fn a_chunk_under_another_key_is_never_deleted() {
    // This could be a wrong key rather than damage. Deleting would destroy
    // history that's still recoverable.
    let dir = TempDir::new().unwrap();
    let engine = open(dir.path());
    engine.append(sample(0, true)).unwrap();
    engine.close().unwrap();
    {
        let conn = remind_store::open_writer(
            &dir.path().join("vault.db"),
            &remind_store::DbKey(master().database_key()),
        )
        .unwrap();
        conn.execute_batch("UPDATE chunk SET sealed = 0").unwrap();
    }
    let chunks = chunk_files(dir.path());

    // Keep the database readable, but give chunks a different key.
    let other = dir.path().join("elsewhere");
    let moved = other.join("chunks/zz/foreign.chunk");
    std::fs::create_dir_all(moved.parent().unwrap()).unwrap();
    std::fs::copy(&chunks[0], &moved).unwrap();
    let (engine, report) =
        Engine::open(&other, MasterKey::from_bytes([9; 32]), config()).unwrap();
    assert_eq!(report.chunks_unreadable, 1);
    assert_eq!(report.chunks_removed, 0);
    assert!(moved.exists());
    engine.close().unwrap();
}
