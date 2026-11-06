//! Spike 5: do text runs save enough, and does one database scale?
//!
//! ```text
//! fixturegen build <dir> <frames> union|exact|per-frame [jitter%]
//! fixturegen query <dir>
//! fixturegen recall <union-dir> <per-frame-dir>
//! ```
//!
//! It builds a synthetic stream of OCR output: several apps, each with documents,
//! with people dwelling, typing, scrolling, and switching. A share of lines can
//! be misread differently on each frame, to model OCR jitter.
//!
//! Words are Zipf-distributed, like natural text. The same seed gives the same
//! corpus, so policies can be compared. Real text will differ, so these numbers are
//! estimates until compared with real use.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::{Duration, Instant};

use elodie_search::{Facets, Order, Query, Search};
use elodie_store::project::{self, ChunkInfo, LoggedFrame};
use elodie_store::{DbKey, FrameContext, open_reader, open_writer, schema, text};
use elodie_text::{OcrLine, OpenRun, Rect, RunPolicy, prepare_lines};
use rusqlite::{Connection, params};

const KEY: DbKey = DbKey([0x42; 32]);
const TICK_MS: i64 = 2000;
const VISIBLE_LINES: usize = 80;
const MAX_AGE: i64 = 5 * 60 * 1000;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, limit: usize) -> usize {
        (self.next() % limit.max(1) as u64) as usize
    }
    fn unit(&mut self) -> f64 {
        self.next() as f64 / u64::MAX as f64
    }
}

fn vocabulary() -> Vec<String> {
    let text = std::fs::read_to_string("/usr/share/dict/words").expect("needs the system word list");
    let mut rng = Rng(0xABCD_EF01_2345_6789);
    let mut words: Vec<String> = text
        .lines()
        .filter(|w| w.len() >= 3 && w.len() <= 11 && w.chars().all(|c| c.is_ascii_lowercase()))
        .map(str::to_owned)
        .collect();
    // Shuffle, so frequency doesn't follow the alphabet.
    for i in (1..words.len()).rev() {
        let j = rng.below(i + 1);
        words.swap(i, j);
    }
    words
}

/// Draws words so that a few are very common and most are rare, like real text.
fn zipf_word<'a>(vocabulary: &'a [String], rng: &mut Rng) -> &'a str {
    let index = ((vocabulary.len() as f64).powf(rng.unit()) - 1.0) as usize;
    &vocabulary[index.min(vocabulary.len() - 1)]
}

fn make_line(vocabulary: &[String], rng: &mut Rng) -> String {
    let count = 3 + rng.below(10);
    let mut line = String::with_capacity(count * 8);
    for i in 0..count {
        if i > 0 {
            line.push(' ');
        }
        line.push_str(zipf_word(vocabulary, rng));
    }
    line
}

/// A document someone can read and scroll, which stays the same when revisited.
struct Document {
    lines: Vec<String>,
    position: usize,
}

struct App {
    bundle_id: String,
    window: String,
    documents: Vec<Document>,
    current: usize,
}

/// Simulates someone using their computer.
struct Corpus<'a> {
    vocabulary: &'a [String],
    rng: Rng,
    apps: Vec<App>,
    current: usize,
    jitter: f64,
}

impl<'a> Corpus<'a> {
    fn new(vocabulary: &'a [String], jitter: f64) -> Self {
        let mut rng = Rng(0x1357_9BDF_0246_8ACE);
        let apps = (0..8)
            .map(|index| {
                let documents = (0..12)
                    .map(|_| Document {
                        lines: (0..400).map(|_| make_line(vocabulary, &mut rng)).collect(),
                        position: 0,
                    })
                    .collect();
                App {
                    bundle_id: format!("com.example.app{index}"),
                    window: format!("{} {}", zipf_word(vocabulary, &mut rng), index),
                    documents,
                    current: 0,
                }
            })
            .collect();
        Self { vocabulary, rng, apps, current: 0, jitter }
    }

    /// Advances one tick and returns what's on screen.
    fn tick(&mut self) -> (usize, Vec<String>) {
        let roll = self.rng.unit();
        if roll < 0.02 {
            self.current = self.rng.below(self.apps.len());
        }
        let vocabulary = self.vocabulary;
        let app_index = self.current;
        let app = &mut self.apps[app_index];
        if roll < 0.02 {
            app.current = self.rng.below(app.documents.len());
        }
        let document = &mut app.documents[app.current];

        if roll < 0.30 {
            // Scrolling by part of a screen.
            let by = 1 + self.rng.below(VISIBLE_LINES / 3);
            document.position = (document.position + by) % document.lines.len();
        } else if roll < 0.75 {
            // Typing: changes one line on screen.
            let at = (document.position + self.rng.below(VISIBLE_LINES)) % document.lines.len();
            let word = zipf_word(vocabulary, &mut self.rng);
            document.lines[at].push(' ');
            document.lines[at].push_str(word);
        }
        // Otherwise reading, and nothing changes.

        let mut lines = Vec::with_capacity(VISIBLE_LINES);
        for offset in 0..VISIBLE_LINES {
            let line = &document.lines[(document.position + offset) % document.lines.len()];
            if self.rng.unit() < self.jitter {
                // OCR misread a character, differently on each frame.
                let mut chars: Vec<char> = line.chars().collect();
                let at = self.rng.below(chars.len());
                chars[at] = (b'a' + self.rng.below(26) as u8) as char;
                lines.push(chars.into_iter().collect());
            } else {
                lines.push(line.clone());
            }
        }
        (app_index, lines)
    }
}

fn policy(name: &str) -> RunPolicy {
    match name {
        "union" => RunPolicy::Union { min_similarity: 0.8, max_age_ms: MAX_AGE },
        "exact" => RunPolicy::Exact { max_age_ms: MAX_AGE },
        "per-frame" => RunPolicy::PerFrame,
        other => panic!("unknown policy {other}"),
    }
}

fn build(directory: &Path, frames: u64, policy_name: &str, jitter_percent: f64) {
    std::fs::create_dir_all(directory).unwrap();
    let path = directory.join("vault.db");
    let mut conn = open_writer(&path, &KEY).unwrap();
    schema::migrate(&mut conn).unwrap();

    let vocabulary = vocabulary();
    let mut corpus = Corpus::new(&vocabulary, jitter_percent / 100.0);
    let run_policy = policy(policy_name);
    let mut run: Option<OpenRun> = None;
    let started = Instant::now();
    let chunk = ChunkInfo {
        uuid: [1; 16],
        display_uuid: [2; 16],
        width: 3024,
        height: 1964,
        path: "chunks/synthetic".to_owned(),
    };

    let mut tx = conn.transaction().unwrap();
    for seq in 0..frames {
        let (app_index, lines) = corpus.tick();
        let app = &corpus.apps[app_index];
        let t_ms = 1_700_000_000_000 + seq as i64 * TICK_MS;
        project::apply_one(
            &tx,
            &LoggedFrame {
                chunk: chunk.clone(),
                seq,
                offset: seq * 100,
                len: 100,
                t_ms,
                is_sync: seq % 30 == 0,
                context: FrameContext {
                    bundle_id: Some(app.bundle_id.clone()),
                    window: Some(app.window.clone()),
                    ..FrameContext::default()
                },
            },
        )
        .unwrap();
        let frame_id = tx.last_insert_rowid();
        let segment_id: Option<i64> = tx
            .query_row("SELECT segment_id FROM frame WHERE id = ?1", params![frame_id], |r| r.get(0))
            .unwrap();

        let ocr: Vec<OcrLine> = lines
            .into_iter()
            .enumerate()
            .map(|(row, text)| OcrLine {
                text,
                rect: Rect { x: 0.1, y: row as f32 / 90.0, width: 0.6, height: 0.01 },
            })
            .collect();
        let prepared = prepare_lines(ocr, None);
        let joins = run.as_ref().is_some_and(|r| r.accepts(run_policy, segment_id, t_ms, &prepared));
        if !joins {
            run = Some(OpenRun::new(segment_id, 1, t_ms, &prepared));
        }
        let current = run.as_mut().unwrap();
        let shown = current.add(t_ms, &prepared);
        let run_id = text::write_run(&tx, current).unwrap();
        text::write_frame_text(&tx, frame_id, run_id, &shown).unwrap();

        if seq % 2000 == 1999 {
            tx.commit().unwrap();
            tx = conn.transaction().unwrap();
        }
        if seq % 500_000 == 499_999 {
            println!("  {} frames, {:.0}/s", seq + 1, (seq + 1) as f64 / started.elapsed().as_secs_f64());
        }
    }
    tx.commit().unwrap();
    conn.execute_batch("UPDATE chunk SET sealed = 1; PRAGMA wal_checkpoint(TRUNCATE);").unwrap();

    let runs: i64 = conn.query_row("SELECT count(*) FROM text_run", [], |r| r.get(0)).unwrap();
    let size = std::fs::metadata(&path).unwrap().len();
    println!(
        "{policy_name}, jitter {jitter_percent}%: {frames} frames, {runs} runs ({:.1} frames per run)",
        frames as f64 / runs.max(1) as f64
    );
    println!(
        "  {:.0} MB, {:.0} bytes per frame, built in {:.0?}, {:.0} frames/s",
        size as f64 / 1e6,
        size as f64 / frames as f64,
        started.elapsed(),
        frames as f64 / started.elapsed().as_secs_f64()
    );
    print_table_sizes(&conn);
}

fn print_table_sizes(conn: &Connection) {
    let Ok(mut stmt) = conn.prepare(
        "SELECT name, sum(pgsize) FROM dbstat GROUP BY name ORDER BY 2 DESC LIMIT 8",
    ) else {
        println!("  (per-table sizes aren't available in this build)");
        return;
    };
    let rows: Vec<(String, i64)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    for (name, bytes) in rows {
        println!("    {name:<28} {:>9.1} MB", bytes as f64 / 1e6);
    }
}

fn percentile(values: &mut [Duration], percent: usize) -> Duration {
    values.sort();
    values[(values.len() - 1) * percent / 100]
}

fn resident_megabytes() -> f64 {
    // SAFETY: `info` is a valid out-pointer of the size passed.
    unsafe {
        let mut info: libc::rusage = std::mem::zeroed();
        libc::getrusage(libc::RUSAGE_SELF, &mut info);
        // On macOS this is in bytes.
        info.ru_maxrss as f64 / 1e6
    }
}

/// Words chosen by how many runs contain them, for realistic query types.
fn terms_by_frequency(conn: &Connection, vocabulary: &[String]) -> (Vec<String>, Vec<String>) {
    let total: i64 = conn.query_row("SELECT count(*) FROM text_run", [], |r| r.get(0)).unwrap();
    let mut common = Vec::new();
    let mut rare = Vec::new();
    let mut rng = Rng(0x7777_1234_5678_9ABC);
    let mut tried = 0;
    while (common.len() < 30 || rare.len() < 30) && tried < 4000 {
        tried += 1;
        let word = if common.len() < 30 && tried % 2 == 0 {
            // The head of the distribution holds the common words.
            &vocabulary[rng.below(40)]
        } else {
            zipf_word(vocabulary, &mut rng)
        };
        let matches: i64 = conn
            .query_row(
                "SELECT count(*) FROM (SELECT 1 FROM run_fts WHERE run_fts MATCH ?1 LIMIT 20000)",
                params![format!("\"{word}\"")],
                |r| r.get(0),
            )
            .unwrap_or(0);
        // Counting stops at the limit, so the bar for "common" can't be above it.
        if matches >= (total / 3).min(20_000) && common.len() < 30 {
            common.push(word.to_owned());
        } else if (1..=200).contains(&matches) && rare.len() < 30 {
            rare.push(word.to_owned());
        }
    }
    (common, rare)
}

fn timed_first_pages(conn: &Connection, queries: &[String], order: Order) -> (Duration, Duration, usize) {
    timed_with_window(conn, queries, order, elodie_search::DEFAULT_RANKING_WINDOW)
}

fn timed_with_window(conn: &Connection, queries: &[String], order: Order, window: i64) -> (Duration, Duration, usize) {
    let mut times = Vec::with_capacity(queries.len());
    let mut hits = 0;
    for query in queries {
        let parsed = Query::parse(query).unwrap();
        let started = Instant::now();
        let mut search = Search::with_ranking_window(conn, parsed, Facets::default(), order, window).unwrap();
        let page = search.next_page(conn).unwrap();
        times.push(started.elapsed());
        hits += page.hits.len();
    }
    (percentile(&mut times, 50), percentile(&mut times, 95), hits / queries.len().max(1))
}

fn query(directory: &Path) {
    let path = directory.join("vault.db");
    let conn = open_reader(&path, &KEY).unwrap();
    let vocabulary = vocabulary();
    let frames: i64 = conn.query_row("SELECT count(*) FROM frame", [], |r| r.get(0)).unwrap();
    println!("{frames} frames, {:.0} MB", std::fs::metadata(&path).unwrap().len() as f64 / 1e6);

    let (common, rare) = terms_by_frequency(&conn, &vocabulary);
    println!("  {} common terms, {} rare terms", common.len(), rare.len());
    // These are the slow queries, so the measurement means nothing without them.
    assert!(!common.is_empty(), "no common terms were found, so the worst case wasn't measured");
    let pairs: Vec<String> = common
        .iter()
        .zip(rare.iter().cycle())
        .map(|(a, b)| format!("{a} {b} "))
        .collect();
    let prefixes: Vec<String> =
        common.iter().filter(|w| w.len() >= 4).map(|w| w[..3].to_owned()).collect();
    let common_terms: Vec<String> = common.iter().map(|w| format!("{w} ")).collect();
    let rare_terms: Vec<String> = rare.iter().map(|w| format!("{w} ")).collect();

    println!("  first page of results:                p50       p95   avg hits");
    for (name, queries, order) in [
        ("common term, relevance", &common_terms, Order::Relevance),
        ("common term, newest", &common_terms, Order::Newest),
        ("rare term, relevance", &rare_terms, Order::Relevance),
        ("common AND rare", &pairs, Order::Relevance),
        ("3-letter prefix, newest", &prefixes, Order::Newest),
        ("3-letter prefix, relevance", &prefixes, Order::Relevance),
    ] {
        if queries.is_empty() {
            continue;
        }
        let (p50, p95, hits) = timed_first_pages(&conn, queries, order);
        println!("    {name:<32} {:>7.1?} {:>9.1?} {hits:>6}", p50, p95);
    }
    println!("  peak memory {:.0} MB", resident_megabytes());
    drop(conn);

    // Deleting a day: the frames, runs, and index entries for 43,200 ticks is more
    // than a real day can have, so this is pessimistic.
    let mut writer = open_writer(&path, &KEY).unwrap();
    let (from, to): (i64, i64) = writer
        .query_row("SELECT min(t_ms), min(t_ms) + 86400000 FROM frame", [], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .unwrap();
    let started = Instant::now();
    let tx = writer.transaction().unwrap();
    let runs: Vec<i64> = {
        let mut stmt = tx.prepare("SELECT id FROM text_run WHERE t_last < ?1").unwrap();
        stmt.query_map(params![to], |r| r.get(0)).unwrap().map(Result::unwrap).collect()
    };
    for run in &runs {
        tx.execute("DELETE FROM run_fts WHERE rowid = ?1", params![run]).unwrap();
    }
    let deleted = tx.execute("DELETE FROM frame WHERE t_ms >= ?1 AND t_ms < ?2", params![from, to]).unwrap();
    tx.execute("DELETE FROM text_run WHERE t_last < ?1", params![to]).unwrap();
    tx.commit().unwrap();
    println!("  deleting one day ({deleted} frames, {} runs) took {:.2?}", runs.len(), started.elapsed());
}

/// How much does the ranking window cost, and how much do results change?
fn windows(directory: &Path) {
    // A vault built by an older version needs bringing up to date first.
    let started = Instant::now();
    let mut writer = open_writer(&directory.join("vault.db"), &KEY).unwrap();
    schema::migrate(&mut writer).unwrap();
    drop(writer);
    println!("migrated in {:.1?}", started.elapsed());
    let conn = open_reader(&directory.join("vault.db"), &KEY).unwrap();
    let vocabulary = vocabulary();
    let (common, rare) = terms_by_frequency(&conn, &vocabulary);
    assert!(!common.is_empty(), "no common terms were found");
    let common_terms: Vec<String> = common.iter().map(|w| format!("{w} ")).collect();
    let prefixes: Vec<String> = common.iter().filter(|w| w.len() >= 4).map(|w| w[..3].to_owned()).collect();
    let rare_terms: Vec<String> = rare.iter().map(|w| format!("{w} ")).collect();

    println!("window     common p50  common p95  prefix p95   rare p95");
    for window in [100_000, 50_000, 25_000, 10_000, 5_000, 2_000] {
        let (p50, p95, _) = timed_with_window(&conn, &common_terms, Order::Relevance, window);
        let (_, prefix95, _) = timed_with_window(&conn, &prefixes, Order::Relevance, window);
        let (_, rare95, _) = timed_with_window(&conn, &rare_terms, Order::Relevance, window);
        println!("{window:>7} {:>11.1?} {:>11.1?} {:>11.1?} {:>10.1?}", p50, p95, prefix95, rare95);
    }
}

/// Recall: does each frame's text still lead to that frame under this policy?
fn recall(union_dir: &Path, baseline_dir: &Path) {
    let union = open_reader(&union_dir.join("vault.db"), &KEY).unwrap();
    let baseline = open_reader(&baseline_dir.join("vault.db"), &KEY).unwrap();
    let mut rng = Rng(0xDEAD_BEEF_1234_5678);
    let total: i64 = baseline.query_row("SELECT count(*) FROM frame", [], |r| r.get(0)).unwrap();

    let mut single_checked = 0;
    let mut single_found = 0;
    let mut pair_checked = 0;
    let mut pair_found = 0;
    let mut pair_raw_matches = 0;
    let mut pair_kept = 0;

    let word_set = |line: &str| -> Vec<String> { line.split(' ').map(str::to_owned).collect() };

    for _ in 0..3000 {
        let frame_id = 1 + rng.below(total as usize) as i64;
        // What this frame shows, from the per-frame baseline.
        let (run_id, lines_z): (i64, Vec<u8>) = baseline
            .query_row(
                "SELECT t.run_id, t.lines_z FROM frame_text t WHERE t.frame_id = ?1",
                params![frame_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        let run_lines: Vec<u8> = baseline
            .query_row("SELECT lines_z FROM text_run WHERE id = ?1", params![run_id], |r| r.get(0))
            .unwrap();
        let lines = elodie_text::codec::decode_lines(&run_lines).unwrap();
        let shown = elodie_text::codec::decode_frame_lines(&lines_z).unwrap();
        if shown.len() < 2 {
            continue;
        }
        let first = &lines[shown[rng.below(shown.len())].0 as usize].text;
        let second = &lines[shown[rng.below(shown.len())].0 as usize].text;
        let a_words = word_set(first);
        let b_words = word_set(second);
        let a = &a_words[rng.below(a_words.len())];
        let b = &b_words[rng.below(b_words.len())];

        // Is the same frame's run returned by the index, under the union policy?
        let union_run: Option<i64> = union
            .query_row("SELECT run_id FROM frame WHERE id = ?1", params![frame_id], |r| r.get(0))
            .unwrap();
        let Some(union_run) = union_run else { continue };

        let matches_run = |expression: &str| -> bool {
            union
                .query_row(
                    "SELECT 1 FROM run_fts WHERE run_fts MATCH ?1 AND rowid = ?2",
                    params![expression, union_run],
                    |_| Ok(()),
                )
                .is_ok()
        };

        single_checked += 1;
        if matches_run(&format!("\"{a}\"")) {
            single_found += 1;
        }
        pair_checked += 1;
        if matches_run(&format!("\"{a}\" AND \"{b}\"")) {
            pair_found += 1;
        }

        // How often does the index match a pair that re-checking must reject?
        let expression = format!("\"{a}\" AND \"{b}\"");
        let hits: Vec<i64> = union
            .prepare_cached("SELECT rowid FROM run_fts WHERE run_fts MATCH ?1 LIMIT 40")
            .unwrap()
            .query_map(params![expression], |r| r.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        pair_raw_matches += hits.len();
        for run in hits {
            if pair_co_visible(&union, run, a, b) {
                pair_kept += 1;
            }
        }
    }
    println!("Recall against the per-frame baseline:");
    println!("  single words  {single_found} of {single_checked} ({:.3}%)", 100.0 * f64::from(single_found) / f64::from(single_checked.max(1)));
    println!("  word pairs    {pair_found} of {pair_checked} ({:.3}%)", 100.0 * f64::from(pair_found) / f64::from(pair_checked.max(1)));
    println!(
        "  of {pair_raw_matches} runs the index matched for pairs, {pair_kept} had a frame showing both ({:.1}% kept)",
        100.0 * pair_kept as f64 / pair_raw_matches.max(1) as f64
    );
}

/// Whether any one frame in a run shows both words, using stored text exactly.
fn pair_co_visible(conn: &Connection, run: i64, a: &str, b: &str) -> bool {
    let run_lines: Vec<u8> = conn
        .query_row("SELECT lines_z FROM text_run WHERE id = ?1", params![run], |r| r.get(0))
        .unwrap();
    let lines = elodie_text::codec::decode_lines(&run_lines).unwrap();
    let has = |needle: &str| -> HashSet<u32> {
        lines
            .iter()
            .enumerate()
            .filter(|(_, line)| line.text.split(' ').any(|word| word == needle))
            .map(|(number, _)| number as u32)
            .collect()
    };
    let (with_a, with_b) = (has(a), has(b));
    let mut stmt = conn.prepare_cached("SELECT lines_z FROM frame_text WHERE run_id = ?1").unwrap();
    let frames = stmt.query_map(params![run], |r| r.get::<_, Vec<u8>>(0)).unwrap();
    for frame in frames {
        let shown: HashSet<u32> = elodie_text::codec::decode_frame_lines(&frame.unwrap())
            .unwrap()
            .into_iter()
            .map(|(number, _)| number)
            .collect();
        if !shown.is_disjoint(&with_a) && !shown.is_disjoint(&with_b) {
            return true;
        }
    }
    false
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let _: HashMap<(), ()> = HashMap::new();
    match args.get(1).map(String::as_str) {
        Some("build") => build(
            Path::new(&args[2]),
            args[3].parse().unwrap(),
            &args[4],
            args.get(5).map_or(0.0, |v| v.parse().unwrap()),
        ),
        Some("query") => query(Path::new(&args[2])),
        Some("windows") => windows(Path::new(&args[2])),
        Some("recall") => recall(Path::new(&args[2]), Path::new(&args[3])),
        _ => eprintln!("usage: fixturegen build|query|recall ..."),
    }
}
