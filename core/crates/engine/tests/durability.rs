//! The engine's behaviour within one process. `tools/torture` covers real kills.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use elodie_engine::{AppendOutcome, Engine, EngineConfig, FrameContext, Sample};
use elodie_vault::MasterKey;
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
        let conn = elodie_store::open_writer(
            &dir.path().join("vault.db"),
            &elodie_store::DbKey(master().database_key()),
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
    std::fs::write(&torn, b"ELDCH").unwrap();

    let (engine, report) = Engine::open(dir.path(), master(), config()).unwrap();
    assert_eq!(report.chunks_removed, 1);
    assert!(!torn.exists());
    engine.close().unwrap();
}

/// Makes every chunk look unsealed, as they would be after a real power cut.
fn mark_unsealed(root: &Path) {
    let conn = elodie_store::open_writer(
        &root.join("vault.db"),
        &elodie_store::DbKey(master().database_key()),
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
        let conn = elodie_store::open_writer(
            &dir.path().join("vault.db"),
            &elodie_store::DbKey(master().database_key()),
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

mod deleting {
    use super::*;
    use elodie_engine::{OcrBatchOptions, OcrLine, OcrResult, Rect};
    use elodie_search::{Facets, Order, Query};

    const T0: i64 = 1_000_000;

    fn t(n: u64) -> i64 {
        T0 + n as i64 * 2000
    }

    /// Records frames, with a keyframe every `gop`, each showing `word<n>`.
    fn recorded(root: &Path, count: u64, gop: u64) -> Engine {
        let engine = open(root);
        for n in 0..count {
            engine.append(sample(n, n % gop == 0)).unwrap();
        }
        wait_for(&engine, count);
        let jobs = engine
            .next_ocr_batch(OcrBatchOptions { max: 10_000, now_ms: T0, include_deferred: false })
            .unwrap();
        engine
            .submit_ocr(
                jobs.iter()
                    .map(|job| OcrResult {
                        frame_id: job.frame_id,
                        lines: vec![
                            OcrLine { text: "shared line".to_owned(), rect: Rect::default() },
                            OcrLine { text: format!("word{}", (job.t_ms - T0) / 2000), rect: Rect::default() },
                        ],
                    })
                    .collect(),
            )
            .unwrap();
        engine
    }

    fn hits(engine: &Engine, query: &str) -> usize {
        let session = engine
            .search(Query::parse(query).unwrap(), Facets::default(), Order::Newest)
            .unwrap();
        session.next_page().unwrap().hits.len()
    }

    #[test]
    fn deleting_everything_removes_files_rows_and_text() {
        let dir = TempDir::new().unwrap();
        let engine = recorded(dir.path(), 10, 5);
        assert_eq!(hits(&engine, "word3 "), 1);

        assert_eq!(engine.delete_range(i64::MIN, i64::MAX).unwrap(), 10);
        assert_eq!(frame_count(&engine), 0);
        assert_eq!(scalar(&engine, "SELECT count(*) FROM text_run"), 0);
        assert_eq!(scalar(&engine, "SELECT count(*) FROM segment"), 0);
        assert_eq!(scalar(&engine, "SELECT count(*) FROM chunk"), 0);
        assert!(chunk_files(dir.path()).is_empty());
        assert_eq!(hits(&engine, "word3 "), 0);
        engine.close().unwrap();
    }

    #[test]
    fn frames_outside_the_range_stay_and_still_decode() {
        let dir = TempDir::new().unwrap();
        let engine = recorded(dir.path(), 20, 5);

        // Frames 7 and 8 go, and 9 too, because it depends on them. 10 is a keyframe.
        assert_eq!(engine.delete_range(t(7), t(8)).unwrap(), 3);

        let earlier = engine.lookup(&DISPLAY, t(6)).unwrap().unwrap();
        let group = engine.read_gop(earlier.id).unwrap();
        assert_eq!(group.samples.iter().map(|s| s.mono_ns).collect::<Vec<_>>(), [5, 6]);
        assert_eq!(group.samples[1].data, vec![6; 100]);

        // Looking at the deleted time now lands on the last frame before it.
        assert_eq!(engine.lookup(&DISPLAY, t(8)).unwrap().unwrap().t_ms, t(6));

        let later = engine.lookup(&DISPLAY, t(12)).unwrap().unwrap();
        let group = engine.read_gop(later.id).unwrap();
        assert_eq!(group.samples.iter().map(|s| s.mono_ns).collect::<Vec<_>>(), [10, 11, 12, 13, 14]);
        assert!(group.samples[0].is_sync);
        engine.close().unwrap();
    }

    /// The point of deleting: the bytes have to be gone from the file, even though
    /// they're encrypted, and the text has to be gone from the database.
    #[test]
    fn deleted_text_cannot_be_found_or_read_back() {
        let dir = TempDir::new().unwrap();
        let engine = recorded(dir.path(), 15, 5);
        assert_eq!(hits(&engine, "word7 "), 1);

        engine.delete_range(t(7), t(7)).unwrap();
        assert_eq!(hits(&engine, "word7 "), 0);
        // Frames around it are unaffected.
        assert_eq!(hits(&engine, "word6 "), 1);
        assert_eq!(hits(&engine, "word11 "), 1);

        // Word 7 was in a run that still has other frames, and it's gone from the
        // run's stored lines too, as well as from the index.
        let conn = engine.open_reader().unwrap();
        let mut statement = conn.prepare("SELECT lines_z FROM text_run").unwrap();
        let blobs: Vec<Vec<u8>> =
            statement.query_map([], |r| r.get(0)).unwrap().map(Result::unwrap).collect();
        for blob in blobs {
            let lines = elodie_text::codec::decode_lines(&blob).unwrap();
            assert!(lines.iter().all(|line| line.text != "word7"), "deleted text is still stored");
        }
        engine.close().unwrap();
    }

    #[test]
    fn an_old_chunk_is_physically_removed_when_rewritten() {
        let dir = TempDir::new().unwrap();
        let engine = recorded(dir.path(), 10, 5);
        engine.seal_all().unwrap();
        let before = chunk_files(dir.path());
        assert_eq!(before.len(), 1);

        engine.delete_range(t(2), t(2)).unwrap();
        let after = chunk_files(dir.path());
        assert_eq!(after.len(), 1);
        assert_ne!(before[0], after[0]);
        assert!(!before[0].exists());
        // Nothing's waiting to be finished.
        assert_eq!(scalar(&engine, "SELECT count(*) FROM purge"), 0);
        assert!(!dir.path().join("rewrite").read_dir().is_ok_and(|mut d| d.next().is_some()));
        engine.close().unwrap();
    }

    #[test]
    fn recording_carries_on_after_a_deletion() {
        let dir = TempDir::new().unwrap();
        let engine = recorded(dir.path(), 10, 5);
        engine.delete_range(t(2), t(3)).unwrap();
        assert_eq!(engine.append(sample(20, false)).unwrap(), AppendOutcome::NeedsKeyframe);
        assert_eq!(engine.append(sample(21, true)).unwrap(), AppendOutcome::Accepted);
        engine.close().unwrap();
        let (engine, report) = Engine::open(dir.path(), master(), config()).unwrap();
        assert_eq!(report.chunks_unreadable, 0);
        assert!(engine.lookup(&DISPLAY, t(21)).unwrap().is_some());
        engine.close().unwrap();
    }

    #[test]
    fn a_deletion_survives_a_relaunch_and_nothing_comes_back() {
        let dir = TempDir::new().unwrap();
        let engine = recorded(dir.path(), 10, 5);
        engine.delete_range(t(2), t(3)).unwrap();
        let remaining = frame_count(&engine);
        engine.close().unwrap();

        let (engine, _) = Engine::open(dir.path(), master(), config()).unwrap();
        assert_eq!(frame_count(&engine), remaining);
        assert_eq!(hits(&engine, "word2 "), 0);
        assert_eq!(hits(&engine, "word1 "), 1);
        engine.close().unwrap();
    }

    /// The crash case: the transaction committed, but the old file is still there.
    /// Recovery must remove it instead of replaying deleted frames.
    #[test]
    fn a_crash_after_commit_does_not_bring_deleted_frames_back() {
        let dir = TempDir::new().unwrap();
        let engine = recorded(dir.path(), 10, 5);
        engine.seal_all().unwrap();
        let old = chunk_files(dir.path()).remove(0);
        let saved = std::fs::read(&old).unwrap();
        engine.delete_range(t(2), t(3)).unwrap();
        let remaining = frame_count(&engine);
        engine.close().unwrap();

        // Put back the state a crash would leave: old file present, and marked for removal.
        std::fs::write(&old, &saved).unwrap();
        {
            let conn = elodie_store::open_writer(
                &dir.path().join("vault.db"),
                &elodie_store::DbKey(master().database_key()),
            )
            .unwrap();
            let relative = old.strip_prefix(dir.path()).unwrap().to_str().unwrap();
            conn.execute("INSERT INTO purge(path) VALUES (?1)", [relative]).unwrap();
        }

        let (engine, _) = Engine::open(dir.path(), master(), config()).unwrap();
        assert!(!old.exists(), "the deleted chunk should have been removed");
        assert_eq!(frame_count(&engine), remaining);
        assert_eq!(hits(&engine, "word2 "), 0);
        engine.close().unwrap();
    }

    /// The other crash case: a rewrite finished writing, but never committed.
    #[test]
    fn a_crash_before_commit_discards_the_rewrite() {
        let dir = TempDir::new().unwrap();
        let engine = recorded(dir.path(), 10, 5);
        let before = frame_count(&engine);
        engine.close().unwrap();

        let rewrite = dir.path().join("rewrite");
        std::fs::create_dir_all(&rewrite).unwrap();
        let stray = rewrite.join("00112233445566778899aabbccddeeff.chunk");
        std::fs::write(&stray, b"leftover from a crash").unwrap();

        let (engine, _) = Engine::open(dir.path(), master(), config()).unwrap();
        assert!(!stray.exists());
        assert_eq!(frame_count(&engine), before);
        engine.close().unwrap();
    }

    /// The last crash case: it committed, but the new file was never moved into place.
    #[test]
    fn a_crash_between_commit_and_move_finishes_the_move() {
        let dir = TempDir::new().unwrap();
        let engine = recorded(dir.path(), 10, 5);
        engine.delete_range(t(2), t(3)).unwrap();
        let remaining = frame_count(&engine);
        engine.close().unwrap();

        let chunk = chunk_files(dir.path()).remove(0);
        let name = chunk.file_name().unwrap().to_owned();
        let rewrite = dir.path().join("rewrite");
        std::fs::create_dir_all(&rewrite).unwrap();
        std::fs::rename(&chunk, rewrite.join(&name)).unwrap();

        let (engine, _) = Engine::open(dir.path(), master(), config()).unwrap();
        assert!(chunk.exists());
        assert_eq!(frame_count(&engine), remaining);
        let last = engine.lookup(&DISPLAY, i64::MAX).unwrap().unwrap();
        assert!(engine.read_gop(last.id).is_ok());
        engine.close().unwrap();
    }
}

mod transcripts {
    use super::*;
    use elodie_engine::SpokenWord;
    use elodie_search::{Facets, Order, Query};

    fn said(text: &str, t_ms: i64, is_me: bool) -> SpokenWord {
        SpokenWord { text: text.to_owned(), t_ms, duration_ms: 300, confidence: 0.87, is_me }
    }

    fn sentence(text: &str, start: i64, is_me: bool) -> Vec<SpokenWord> {
        text.split(' ')
            .enumerate()
            .map(|(index, word)| said(word, start + index as i64 * 350, is_me))
            .collect()
    }

    fn search(engine: &Engine, query: &str, facets: Facets) -> Vec<elodie_search::Hit> {
        let session = engine.search(Query::parse(query).unwrap(), facets, Order::Newest).unwrap();
        session.next_page().unwrap().hits
    }

    #[test]
    fn what_was_said_can_be_found_at_the_moment_it_was_said() {
        let dir = TempDir::new().unwrap();
        let engine = open(dir.path());
        engine.append_transcript(sentence("the quarterly budget looks fine", 50_000, false), Some("Design review".to_owned())).unwrap();

        let hits = search(&engine, "budget ", Facets::default());
        assert_eq!(hits.len(), 1);
        assert!(hits[0].is_transcript);
        assert_eq!(hits[0].t_ms, 50_000);
        assert_eq!(hits[0].snippet, "the quarterly budget looks fine");
        assert_eq!(hits[0].window.as_deref(), Some("Design review"));
        engine.close().unwrap();
    }

    /// The reference app interpolated word times and fixed confidence at 1.0.
    #[test]
    fn real_word_times_and_confidence_are_kept() {
        let dir = TempDir::new().unwrap();
        let engine = open(dir.path());
        engine.append_transcript(vec![said("alpha", 1000, true), said("beta", 1300, true)], None).unwrap();
        let words = engine.transcript_words(0, 10_000).unwrap();
        assert_eq!(words[0], ("alpha".to_owned(), 1000, 300, f64::from(0.87f32)));
        assert_eq!(words[1].1, 1300);
        engine.close().unwrap();
    }

    #[test]
    fn the_microphones_echo_of_the_speakers_is_dropped() {
        let dir = TempDir::new().unwrap();
        let engine = open(dir.path());
        let mut words = sentence("hello everyone", 1000, false);
        words.extend(sentence("hello everyone", 1100, true));
        words.push(said("thanks", 3000, true));
        engine.append_transcript(words, None).unwrap();

        let lines = engine.transcript(0, 10_000).unwrap();
        let mine: Vec<_> = lines.iter().filter(|line| line.is_me).map(|line| line.text.as_str()).collect();
        assert_eq!(mine, ["thanks"]);
        assert_eq!(lines.iter().filter(|line| !line.is_me).count(), 1);
        engine.close().unwrap();
    }

    #[test]
    fn lines_split_on_a_change_of_speaker_or_a_pause() {
        let dir = TempDir::new().unwrap();
        let engine = open(dir.path());
        let mut words = sentence("first thought", 1000, true);
        words.extend(sentence("second thought", 5000, true));
        words.extend(sentence("reply here", 6000, false));
        engine.append_transcript(words, None).unwrap();
        let texts: Vec<String> = engine.transcript(0, 20_000).unwrap().into_iter().map(|line| line.text).collect();
        assert_eq!(texts, ["first thought", "second thought", "reply here"]);
        engine.close().unwrap();
    }

    #[test]
    fn the_meetings_filter_only_returns_what_was_said() {
        let dir = TempDir::new().unwrap();
        let engine = open(dir.path());
        engine.append(sample(0, true)).unwrap();
        wait_for(&engine, 1);
        let jobs = engine
            .next_ocr_batch(elodie_engine::OcrBatchOptions { max: 8, now_ms: T, include_deferred: false })
            .unwrap();
        engine
            .submit_ocr(vec![elodie_engine::OcrResult {
                frame_id: jobs[0].frame_id,
                lines: vec![elodie_engine::OcrLine { text: "budget on screen".to_owned(), rect: elodie_engine::Rect::default() }],
            }])
            .unwrap();
        engine.append_transcript(sentence("budget out loud", 2_000_000, false), None).unwrap();

        assert_eq!(search(&engine, "budget ", Facets::default()).len(), 2);
        let spoken = search(&engine, "budget ", Facets { transcripts_only: true, ..Facets::default() });
        assert_eq!(spoken.len(), 1);
        assert_eq!(spoken[0].snippet, "budget out loud");
        engine.close().unwrap();
    }

    const T: i64 = 1_000_000;

    #[test]
    fn deleting_a_range_removes_what_was_said_in_it() {
        let dir = TempDir::new().unwrap();
        let engine = open(dir.path());
        let mut words = sentence("keep this first", 1000, true);
        words.extend(sentence("forget this secret", 10_000, true));
        words.extend(sentence("keep this last", 20_000, true));
        engine.append_transcript(words, None).unwrap();
        assert_eq!(search(&engine, "secret ", Facets::default()).len(), 1);

        engine.delete_range(9_000, 15_000).unwrap();
        assert!(search(&engine, "secret ", Facets::default()).is_empty());
        let texts: Vec<String> = engine.transcript(0, 100_000).unwrap().into_iter().map(|line| line.text).collect();
        assert_eq!(texts, ["keep this first", "keep this last"]);
        assert!(engine.transcript_words(9_000, 15_000).unwrap().is_empty());
        assert_eq!(search(&engine, "last ", Facets::default()).len(), 1);
        engine.close().unwrap();
    }

    #[test]
    fn deleting_everything_removes_all_of_it() {
        let dir = TempDir::new().unwrap();
        let engine = open(dir.path());
        engine.append_transcript(sentence("alpha beta", 1000, true), None).unwrap();
        engine.delete_range(i64::MIN, i64::MAX).unwrap();
        assert!(engine.transcript(0, i64::MAX).unwrap().is_empty());
        assert!(search(&engine, "alpha ", Facets::default()).is_empty());
        assert_eq!(scalar(&engine, "SELECT count(*) FROM text_run"), 0);
        engine.close().unwrap();
    }
}
