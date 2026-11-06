//! Spike 6: does recorded data survive crashes?
//!
//! ```text
//! torture self-test <dir>             proves the checks detect damage
//! torture kill   <dir> <iterations>   real SIGKILLs at random moments
//! torture power  <dir> <iterations>   SIGKILLs plus simulated power-cut damage
//! torture enospc <dir> <iterations>   a genuinely full disk; <dir> must be on a
//!                                     small volume (see scripts/torture.sh)
//! ```
//!
//! After each crash it reopens the vault and checks that every frame the
//! database knows about decrypts and has the exact bytes written, that each chunk
//! starts with a keyframe and has no gaps, and that everything acknowledged as
//! logged is still there. It exits non-zero on any violation.
//!
//! Power cuts are simulated. It can't remove power, so it damages files the way a
//! lost write cache would: truncated or corrupted chunk tails, and a truncated or
//! missing write-ahead log.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use elodie_engine::{AppendOutcome, Engine, EngineConfig, FrameContext, Sample};
use elodie_store::{DbKey, open_reader};
use elodie_vault::{ChunkReader, MasterKey};

const DISPLAY: [u8; 16] = [0xD1; 16];

fn master() -> MasterKey {
    MasterKey::from_bytes([0x5A; 32])
}

/// A fast generator seeded per run, so failures can be reproduced.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, limit: u64) -> u64 {
        self.next() % limit.max(1)
    }

    fn chance(&mut self, percent: u64) -> bool {
        self.below(100) < percent
    }
}

/// The exact bytes of a sample, derived from its counter so they can be checked.
fn sample_bytes(counter: u64, max_len: u64) -> Vec<u8> {
    let mixed = counter.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    let len = 512 + (mixed >> 32) % max_len;
    let pattern = mixed.to_le_bytes();
    (0..len).map(|i| pattern[(i % 8) as usize] ^ (i >> 8) as u8).collect()
}

fn child_config() -> EngineConfig {
    EngineConfig {
        // Far shorter than production, so rotation and commits happen constantly.
        chunk_max_bytes: 128 * 1024,
        chunk_max_age: Duration::from_millis(250),
        sync_interval: Duration::from_millis(40),
        batch_interval: Duration::from_millis(10),
        sample_queue: 8,
        ..EngineConfig::default()
    }
}

/// Writes frames until killed, reporting progress on stdout as records of
/// (highest accepted counter, logged watermark, frames accepted, frames logged).
fn run_child(root: &Path, start: u64, pace_us: u64, max_len: u64) -> ! {
    use std::io::Write;

    let (engine, _) = match Engine::open(root, master(), child_config()) {
        Ok(opened) => opened,
        // A full disk can make recovery fail. That's reported by the parent.
        Err(_) => {
            std::thread::sleep(Duration::from_secs(60));
            std::process::exit(2);
        }
    };
    let params: Arc<[u8]> = Arc::from(&b"torture parameter sets"[..]);
    let mut stdout = std::io::stdout().lock();
    let mut counter = start;
    let mut accepted = 0;
    let mut accepted_total = 0u64;
    let mut since_sync = 0u64;
    let mut force_sync = true;

    loop {
        let is_sync = force_sync || since_sync >= 30;
        let context = FrameContext {
            bundle_id: Some(format!("com.example.app{}", (counter / 40) % 3)),
            window: (counter % 7 != 0).then(|| format!("Window {}", (counter / 40) % 5)),
            url: None,
            profile: None,
            front_rect: None,
        };
        let sample = Sample {
            display_uuid: DISPLAY,
            width: 640,
            height: 400,
            parameter_sets: Arc::clone(&params),
            // Realistic spacing, so segments form as they would in production.
            wall_ms: 1_800_000_000_000 + counter as i64 * 2000,
            mono_ns: counter,
            is_sync,
            context,
            data: sample_bytes(counter, max_len),
        };
        match engine.append(sample) {
            Ok(AppendOutcome::Accepted) => {
                accepted = counter;
                accepted_total += 1;
                force_sync = false;
                since_sync = if is_sync { 1 } else { since_sync + 1 };
            }
            Ok(AppendOutcome::DroppedQueueFull | AppendOutcome::NeedsKeyframe) => force_sync = true,
            Err(_) => std::process::exit(3),
        }
        counter += 1;

        let mut report = [0u8; 32];
        report[..8].copy_from_slice(&accepted.to_le_bytes());
        report[8..16].copy_from_slice(&engine.logged_watermark().to_le_bytes());
        report[16..24].copy_from_slice(&accepted_total.to_le_bytes());
        report[24..].copy_from_slice(&engine.stats().logged_frames.to_le_bytes());
        if stdout.write_all(&report).and_then(|()| stdout.flush()).is_err() {
            std::process::exit(4);
        }
        if pace_us > 0 {
            std::thread::sleep(Duration::from_micros(pace_us));
        }
    }
}

#[derive(Clone, Copy, Default)]
struct Progress {
    accepted: u64,
    logged: u64,
    accepted_total: u64,
    logged_total: u64,
}

impl Progress {
    /// Frames accepted into the queue but not yet logged at the last report. This
    /// is what a kill at that moment would lose.
    fn in_flight(&self) -> u64 {
        self.accepted_total.saturating_sub(self.logged_total)
    }
}

struct Worker {
    child: Child,
    progress: Arc<Mutex<Progress>>,
    reader: std::thread::JoinHandle<()>,
}

fn spawn_child(root: &Path, start: u64, pace_us: u64, max_len: u64) -> Worker {
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["child", root.to_str().unwrap(), &start.to_string()])
        .args([pace_us.to_string(), max_len.to_string()])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdout = child.stdout.take().unwrap();
    let progress = Arc::new(Mutex::new(Progress::default()));
    let shared = Arc::clone(&progress);
    let reader = std::thread::spawn(move || {
        let mut report = [0u8; 32];
        let field = |r: &[u8; 32], at: usize| u64::from_le_bytes(r[at..at + 8].try_into().unwrap());
        while stdout.read_exact(&mut report).is_ok() {
            *shared.lock().unwrap() = Progress {
                accepted: field(&report, 0),
                logged: field(&report, 8),
                accepted_total: field(&report, 16),
                logged_total: field(&report, 24),
            };
        }
    });
    Worker { child, progress, reader }
}

impl Worker {
    fn kill(mut self) -> Progress {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = self.reader.join();
        *self.progress.lock().unwrap()
    }

    fn logged(&self) -> u64 {
        self.progress.lock().unwrap().logged
    }
}

#[derive(Default)]
struct Checked {
    frames: u64,
    max_counter: u64,
    violations: Vec<String>,
}

/// Checks every chunk with a row ID above `after`.
fn verify(root: &Path, after: i64, max_len: u64) -> Result<(Checked, i64), String> {
    let conn = open_reader(&root.join("vault.db"), &DbKey(master().database_key()))
        .map_err(|e| format!("couldn't open the database: {e}"))?;
    let mut checked = Checked::default();
    let mut newest = after;

    let chunks: Vec<(i64, String, i64)> = {
        let mut stmt = conn
            .prepare("SELECT id, path, sealed FROM chunk WHERE id > ?1 ORDER BY id")
            .map_err(|e| e.to_string())?;
        stmt.query_map([after], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .map_err(|e| e.to_string())?
            .collect::<rusqlite::Result<_>>()
            .map_err(|e| e.to_string())?
    };

    for (chunk_id, path, sealed) in chunks {
        newest = newest.max(chunk_id);
        if sealed != 1 {
            checked.violations.push(format!("chunk {chunk_id} is unsealed after recovery"));
        }
        let full_path = root.join(&path);
        let reader = match ChunkReader::open(&full_path, &master()) {
            Ok(reader) => reader,
            Err(error) => {
                checked.violations.push(format!("chunk {chunk_id}: {error}"));
                continue;
            }
        };
        let rows: Vec<(i64, i64, u32, bool)> = {
            let mut stmt = conn
                .prepare("SELECT seq, offset, len, is_sync FROM frame WHERE chunk_id = ?1 ORDER BY seq")
                .map_err(|e| e.to_string())?;
            stmt.query_map([chunk_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
                .map_err(|e| e.to_string())?
                .collect::<rusqlite::Result<_>>()
                .map_err(|e| e.to_string())?
        };
        if rows.is_empty() {
            checked.violations.push(format!("chunk {chunk_id} has no frames"));
            continue;
        }
        if !rows[0].3 {
            checked.violations.push(format!("chunk {chunk_id} doesn't start with a keyframe"));
        }
        let mut end_of_log = 0;
        for (index, &(seq, offset, len, is_sync)) in rows.iter().enumerate() {
            if seq != index as i64 {
                checked.violations.push(format!("chunk {chunk_id} has a gap at {index}: seq {seq}"));
                break;
            }
            match reader.read_at(seq as u64, offset as u64, len) {
                Err(error) => {
                    checked.violations.push(format!("chunk {chunk_id} seq {seq} undecodable: {error}"));
                }
                Ok(record) => {
                    if record.is_sync() != is_sync {
                        checked.violations.push(format!("chunk {chunk_id} seq {seq}: keyframe flag differs"));
                    }
                    if record.sample != sample_bytes(record.mono_ns, max_len) {
                        checked.violations.push(format!("chunk {chunk_id} seq {seq}: wrong bytes"));
                    }
                    checked.max_counter = checked.max_counter.max(record.mono_ns);
                    checked.frames += 1;
                }
            }
            end_of_log = offset as u64 + u64::from(len);
        }
        let file_len = std::fs::metadata(&full_path).map(|m| m.len()).unwrap_or(0);
        if file_len != end_of_log {
            checked.violations.push(format!(
                "chunk {chunk_id}: file is {file_len} bytes but its records end at {end_of_log}"
            ));
        }
    }

    // Nothing may refer to frames that no longer exist.
    let dangling: i64 = conn
        .query_row(
            "SELECT count(*) FROM frame f WHERE NOT EXISTS (SELECT 1 FROM chunk c WHERE c.id = f.chunk_id)",
            [],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?;
    if dangling > 0 {
        checked.violations.push(format!("{dangling} frames refer to missing chunks"));
    }
    let integrity: String = conn
        .query_row("PRAGMA quick_check", [], |r| r.get(0))
        .map_err(|e| e.to_string())?;
    if integrity != "ok" {
        checked.violations.push(format!("database integrity: {integrity}"));
    }
    Ok((checked, newest))
}

fn percentile(sorted: &[Duration], percent: usize) -> Duration {
    if sorted.is_empty() {
        return Duration::ZERO;
    }
    sorted[(sorted.len() - 1) * percent / 100]
}

#[derive(Default)]
struct Summary {
    iterations: u64,
    frames: u64,
    replayed: u64,
    removed: u64,
    trimmed: u64,
    recoveries: Vec<Duration>,
    /// Most frames queued but unlogged at a kill, when pacing frames.
    in_flight_paced: u64,
    /// The same when flooding the queue, which is bounded by the queue size.
    in_flight_flood: u64,
    violations: Vec<String>,
}

impl Summary {
    fn finish(mut self, name: &str, root: &Path) -> ! {
        self.recoveries.sort();
        let size = directory_size(root);
        println!("{name}:");
        println!("  iterations            {}", self.iterations);
        println!("  frames verified       {}", self.frames);
        println!("  frames replayed       {}", self.replayed);
        println!("  rows past log removed {}", self.removed);
        println!("  chunks trimmed        {}", self.trimmed);
        println!(
            "  recovery              p50 {:?}, p99 {:?}, max {:?}",
            percentile(&self.recoveries, 50),
            percentile(&self.recoveries, 99),
            self.recoveries.last().copied().unwrap_or_default()
        );
        println!("  in flight at kill     paced {}, flooded {}", self.in_flight_paced, self.in_flight_flood);
        println!("  vault size            {:.1} MB", size as f64 / 1e6);
        println!("  violations            {}", self.violations.len());
        for violation in self.violations.iter().take(20) {
            println!("    {violation}");
        }
        std::process::exit(i32::from(!self.violations.is_empty()));
    }
}

fn directory_size(path: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(path) else { return 0 };
    entries
        .flatten()
        .map(|entry| match entry.metadata() {
            Ok(meta) if meta.is_dir() => directory_size(&entry.path()),
            Ok(meta) => meta.len(),
            Err(_) => 0,
        })
        .sum()
}

fn newest_unsealed_chunks(root: &Path) -> Vec<PathBuf> {
    // A real power cut can't undo a sync, so sealed chunks are left alone.
    let mut sealed = std::collections::HashSet::new();
    if let Ok(conn) = open_reader(&root.join("vault.db"), &DbKey(master().database_key())) {
        if let Ok(mut stmt) = conn.prepare("SELECT path FROM chunk WHERE sealed = 1") {
            if let Ok(rows) = stmt.query_map([], |r| r.get::<_, String>(0)) {
                sealed.extend(rows.flatten());
            }
        }
    }
    let mut files = Vec::new();
    let Ok(shards) = std::fs::read_dir(root.join("chunks")) else { return files };
    for shard in shards.flatten() {
        let Ok(entries) = std::fs::read_dir(shard.path()) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let relative = path.strip_prefix(root).unwrap().to_str().unwrap().to_owned();
            if !sealed.contains(&relative) {
                files.push(path);
            }
        }
    }
    files
}

/// Damages files the way losing the drive's write cache could.
fn simulate_power_cut(root: &Path, rng: &mut Rng) {
    for path in newest_unsealed_chunks(root) {
        let Ok(meta) = std::fs::metadata(&path) else { continue };
        let len = meta.len();
        // Headers are synced before the chunk is used, so leave the first 128
        // bytes alone. Separate tests cover damage inside a header.
        if len <= 128 {
            continue;
        }
        let file = std::fs::OpenOptions::new().read(true).write(true).open(&path).unwrap();
        match rng.below(3) {
            0 => file.set_len(128 + rng.below(len - 128)).unwrap(),
            1 => {
                use std::os::unix::fs::FileExt;
                let position = 128 + rng.below(len - 128);
                let mut byte = [0u8; 1];
                file.read_exact_at(&mut byte, position).unwrap();
                byte[0] ^= 1 + rng.below(255) as u8;
                file.write_all_at(&byte, position).unwrap();
            }
            _ => {}
        }
    }
    let wal = root.join("vault.db-wal");
    match rng.below(3) {
        0 => {
            let _ = std::fs::remove_file(&wal);
            let _ = std::fs::remove_file(root.join("vault.db-shm"));
        }
        1 => {
            if let Ok(meta) = std::fs::metadata(&wal) {
                if let Ok(file) = std::fs::OpenOptions::new().write(true).open(&wal) {
                    let _ = file.set_len(rng.below(meta.len().max(1)));
                }
            }
            let _ = std::fs::remove_file(root.join("vault.db-shm"));
        }
        _ => {}
    }
}

fn config() -> EngineConfig {
    child_config()
}

fn recover_and_check(root: &Path, after: i64, max_len: u64, summary: &mut Summary) -> (u64, i64) {
    let started = Instant::now();
    let (engine, report) = match Engine::open(root, master(), config()) {
        Ok(opened) => opened,
        Err(error) => {
            summary.violations.push(format!("recovery failed: {error}"));
            return (0, after);
        }
    };
    let elapsed = started.elapsed();
    summary.recoveries.push(elapsed);
    summary.replayed += report.frames_replayed;
    summary.removed += report.frames_removed;
    summary.trimmed += report.chunks_trimmed;
    if report.chunks_unreadable > 0 {
        summary.violations.push(format!("{} chunks unreadable", report.chunks_unreadable));
    }
    let _ = engine.close();

    match verify(root, after, max_len) {
        Ok((checked, newest)) => {
            summary.frames += checked.frames;
            summary.violations.extend(checked.violations);
            (checked.max_counter, newest)
        }
        Err(error) => {
            summary.violations.push(error);
            (0, after)
        }
    }
}

const MAX_LEN: u64 = 16 * 1024;

fn run_kill(root: &Path, iterations: u64, seed: u64) -> ! {
    std::fs::create_dir_all(root).unwrap();
    let mut rng = Rng(seed);
    let mut summary = Summary::default();
    let mut next = 1;
    let mut after = 0;
    let mut must_survive = 0;
    let mut highest_verified = 0;

    for iteration in 0..iterations {
        summary.iterations += 1;
        // Half are paced like a slow disk. The rest flood the queue.
        let paced = iteration % 2 == 0;
        let pace = std::env::var("TORTURE_PACE_US").ok().and_then(|v| v.parse().ok());
        let worker = spawn_child(root, next, pace.unwrap_or(if paced { 2000 } else { 0 }), MAX_LEN);
        // Very short runs often die during startup or recovery. A slower pace
        // needs a longer run to reach a steady state.
        let run_ms = pace.map_or(150, |us: u64| (us / 1000).max(1) * 8);
        std::thread::sleep(Duration::from_millis(rng.below(run_ms)));
        let progress = worker.kill();
        must_survive = must_survive.max(progress.logged);
        if paced {
            summary.in_flight_paced = summary.in_flight_paced.max(progress.in_flight());
        } else {
            summary.in_flight_flood = summary.in_flight_flood.max(progress.in_flight());
        }

        // Sometimes leave recovery to the next child, which may also be killed
        // partway through. Recovery has to survive being interrupted.
        if rng.chance(25) && iteration + 1 < iterations {
            next = next.max(progress.accepted + 1);
            continue;
        }

        let (max_counter, newest) = recover_and_check(root, after, MAX_LEN, &mut summary);
        after = newest;
        highest_verified = highest_verified.max(max_counter);
        if highest_verified < must_survive {
            summary.violations.push(format!(
                "iteration {iteration}: frame {must_survive} was logged, but the newest recovered is {highest_verified}"
            ));
        }
        next = next.max(progress.accepted.max(max_counter) + 1);
    }
    summary.finish("kill", root);
}

fn run_power(root: &Path, iterations: u64, seed: u64) -> ! {
    std::fs::create_dir_all(root).unwrap();
    let mut rng = Rng(seed);
    let mut summary = Summary::default();
    let mut next = 1;

    for iteration in 0..iterations {
        summary.iterations += 1;
        let worker = spawn_child(root, next, 1000, MAX_LEN);
        std::thread::sleep(Duration::from_millis(30 + rng.below(120)));
        let accepted = worker.kill().accepted;
        simulate_power_cut(root, &mut rng);

        // A lost write-ahead log can roll row IDs back, so check everything.
        let (max_counter, _) = recover_and_check(root, 0, MAX_LEN, &mut summary);
        next = next.max(accepted.max(max_counter) + 1);

        if iteration % 25 == 24 {
            // Keep the full re-check quick.
            for name in ["chunks", "vault.db", "vault.db-wal", "vault.db-shm"] {
                let path = root.join(name);
                let _ = std::fs::remove_dir_all(&path);
                let _ = std::fs::remove_file(&path);
            }
        }
    }
    summary.finish("power", root);
}

fn fill_with_ballast(path: &Path, leave_free: u64) {
    let free = free_space(path.parent().unwrap());
    if free > leave_free {
        use std::io::Write;
        let mut file = std::fs::File::create(path).unwrap();
        let block = vec![0xB5u8; 1024 * 1024];
        for _ in 0..(free - leave_free) / block.len() as u64 {
            if file.write_all(&block).is_err() {
                break;
            }
        }
        let _ = file.sync_all();
    }
}

fn free_space(path: &Path) -> u64 {
    use std::os::unix::ffi::OsStrExt;
    let c_path = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
    // SAFETY: an all-zero `statfs` is a valid value for an out-parameter, and the
    // path is NUL-terminated.
    let (rc, stats) = unsafe {
        let mut stats: libc::statfs = std::mem::zeroed();
        (libc::statfs(c_path.as_ptr(), &mut stats), stats)
    };
    assert_eq!(rc, 0, "statfs failed");
    stats.f_bavail * u64::from(stats.f_bsize)
}

/// Runs until the disk is full, then checks that nothing was damaged and that
/// recording resumes once there's space again.
fn run_enospc(mount: &Path, iterations: u64, seed: u64) -> ! {
    let mut rng = Rng(seed);
    let mut summary = Summary::default();
    let mut next = 1;
    let ballast = mount.join("ballast");
    let relief = mount.join("relief");
    let root = mount.join("vault");
    const SAMPLE: u64 = 256 * 1024;

    for iteration in 0..iterations {
        summary.iterations += 1;
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_file(&ballast);
        let _ = std::fs::remove_file(&relief);
        std::fs::create_dir_all(&root).unwrap();

        // Space to give back afterward, then fill nearly everything else.
        std::fs::write(&relief, vec![0x11u8; 8 * 1024 * 1024]).unwrap();
        fill_with_ballast(&ballast, 3 * 1024 * 1024 + rng.below(3 * 1024 * 1024));

        let worker = spawn_child(&root, next, 500, SAMPLE);

        // Wait for the log to stop advancing, which means the disk is full.
        let mut last = worker.logged();
        let mut stalled_for = Duration::ZERO;
        let deadline = Instant::now() + Duration::from_secs(10);
        while stalled_for < Duration::from_millis(400) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
            let current = worker.logged();
            if current == last {
                stalled_for += Duration::from_millis(50);
            } else {
                stalled_for = Duration::ZERO;
                last = current;
            }
        }
        if Instant::now() >= deadline {
            summary.violations.push(format!("iteration {iteration}: the disk never filled"));
        }

        // Half the time, free space while it's still running: recording must
        // resume by itself.
        let resumed_live = iteration % 2 == 0;
        if resumed_live {
            std::fs::remove_file(&relief).unwrap();
            let before = worker.logged();
            let wait_until = Instant::now() + Duration::from_secs(10);
            while worker.logged() <= before && Instant::now() < wait_until {
                std::thread::sleep(Duration::from_millis(20));
            }
            if worker.logged() <= before {
                summary.violations.push(format!(
                    "iteration {iteration}: recording didn't resume after space was freed"
                ));
            }
        }

        let progress = worker.kill();

        // Opening a vault on a full disk may fail, but it must do no damage.
        if !resumed_live {
            let attempt = Engine::open(&root, master(), config());
            if let Ok((engine, _)) = attempt {
                let _ = engine.close();
            }
            std::fs::remove_file(&relief).unwrap();
        }

        let (max_counter, _) = recover_and_check(&root, 0, SAMPLE, &mut summary);
        if max_counter < progress.logged {
            summary.violations.push(format!(
                "iteration {iteration}: frame {} was logged, but the newest recovered is {max_counter}",
                progress.logged
            ));
        }
        next = next.max(progress.accepted.max(max_counter) + 1);
    }
    let _ = std::fs::remove_file(&ballast);
    let _ = std::fs::remove_file(&relief);
    summary.finish("enospc", &root);
}

/// A negative control. A checker that can't fail proves nothing, so this damages
/// a vault in each way the checks claim to detect and requires a violation.
fn run_self_test(root: &Path) -> ! {
    let mut failures = 0;
    let mut check = |name: &str, damage: &dyn Fn(&Path, &rusqlite::Connection)| {
        let _ = std::fs::remove_dir_all(root);
        std::fs::create_dir_all(root).unwrap();
        let (engine, _) = Engine::open(root, master(), EngineConfig {
            sample_queue: 1024,
            ..child_config()
        }).unwrap();
        let params: Arc<[u8]> = Arc::from(&b"p"[..]);
        for counter in 1..=40u64 {
            let outcome = engine.append(Sample {
                display_uuid: DISPLAY,
                width: 640,
                height: 400,
                parameter_sets: Arc::clone(&params),
                wall_ms: 1_800_000_000_000 + counter as i64 * 2000,
                mono_ns: counter,
                is_sync: counter % 10 == 1,
                context: FrameContext::default(),
                data: sample_bytes(counter, MAX_LEN),
            }).unwrap();
            assert_eq!(outcome, AppendOutcome::Accepted);
        }
        engine.close().unwrap();

        let clean = verify(root, 0, MAX_LEN).unwrap().0;
        assert!(clean.violations.is_empty(), "the clean vault failed: {:?}", clean.violations);

        let conn = elodie_store::open_writer(&root.join("vault.db"), &DbKey(master().database_key())).unwrap();
        damage(root, &conn);
        drop(conn);

        let found = verify(root, 0, MAX_LEN).map(|(c, _)| c.violations).unwrap_or_else(|e| vec![e]);
        if found.is_empty() {
            println!("  NOT DETECTED: {name}");
            failures += 1;
        } else {
            println!("  detected: {name}");
        }
    };

    let path_and_offset = |conn: &rusqlite::Connection| -> (String, i64) {
        conn.query_row(
            "SELECT c.path, f.offset FROM frame f JOIN chunk c ON c.id = f.chunk_id WHERE f.seq = 3 LIMIT 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap()
    };

    println!("self-test:");
    check("a flipped byte in a record", &|root, conn| {
        use std::os::unix::fs::FileExt;
        let (path, offset) = path_and_offset(conn);
        let file = std::fs::OpenOptions::new().read(true).write(true).open(root.join(path)).unwrap();
        let mut byte = [0u8; 1];
        file.read_exact_at(&mut byte, offset as u64 + 40).unwrap();
        byte[0] ^= 0xFF;
        file.write_all_at(&byte, offset as u64 + 40).unwrap();
    });
    check("a missing frame row", &|_, conn| {
        conn.execute("DELETE FROM frame WHERE id = (SELECT id FROM frame WHERE seq = 2 LIMIT 1)", []).unwrap();
    });
    check("a chunk that doesn't start with a keyframe", &|_, conn| {
        conn.execute("UPDATE frame SET is_sync = 0 WHERE seq = 0", []).unwrap();
    });
    check("a chunk left unsealed", &|_, conn| {
        conn.execute("UPDATE chunk SET sealed = 0 WHERE id = (SELECT min(id) FROM chunk)", []).unwrap();
    });
    check("a chunk with trailing bytes", &|root, conn| {
        use std::io::Write;
        let (path, _) = path_and_offset(conn);
        let mut file = std::fs::OpenOptions::new().append(true).open(root.join(path)).unwrap();
        file.write_all(b"junk").unwrap();
    });
    check("a chunk whose file is gone", &|root, conn| {
        let (path, _) = path_and_offset(conn);
        std::fs::remove_file(root.join(path)).unwrap();
    });
    check("a keyframe flag that disagrees with the log", &|_, conn| {
        conn.execute("UPDATE frame SET is_sync = 1 WHERE seq = 5", []).unwrap();
    });
    check("a chunk with no frames", &|_, conn| {
        conn.execute("DELETE FROM frame WHERE chunk_id = (SELECT min(id) FROM chunk)", []).unwrap();
    });

    let _ = std::fs::remove_dir_all(root);
    if failures > 0 {
        println!("  {failures} kinds of damage went undetected");
        std::process::exit(1);
    }
    println!("  all damage detected");
    std::process::exit(0);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let arg = |index: usize| args.get(index).map(String::as_str);
    let parse = |index: usize, default: u64| {
        args.get(index).and_then(|value| value.parse().ok()).unwrap_or(default)
    };
    let seed = std::env::var("TORTURE_SEED")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(0x1234_5678_9ABC_DEF1);

    match (arg(1), arg(2)) {
        (Some("child"), Some(root)) => {
            run_child(Path::new(root), parse(3, 1), parse(4, 0), parse(5, MAX_LEN))
        }
        (Some("self-test"), Some(root)) => run_self_test(Path::new(root)),
        (Some("kill"), Some(root)) => run_kill(Path::new(root), parse(3, 100), seed),
        (Some("power"), Some(root)) => run_power(Path::new(root), parse(3, 100), seed),
        (Some("enospc"), Some(root)) => run_enospc(Path::new(root), parse(3, 20), seed),
        _ => {
            eprintln!("usage: torture self-test|kill|power|enospc <dir> [iterations]");
            std::process::exit(64);
        }
    }
}
