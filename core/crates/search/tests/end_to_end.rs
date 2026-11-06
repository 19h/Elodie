//! Searches against a real encrypted database with the real tokenizer.

use elodie_search::{Facets, Order, Page, Query, Search};
use elodie_store::project::{self, ChunkInfo, LoggedFrame};
use elodie_store::{DbKey, FrameContext, open_writer, schema, text};
use elodie_text::{OcrLine, OpenRun, Rect, RunPolicy, prepare_lines};
use rusqlite::{Connection, params};
use tempfile::TempDir;

const POLICY: RunPolicy = RunPolicy::Union { min_similarity: 0.8, max_age_ms: 300_000 };

/// Builds a vault's text tables directly, without any video.
struct Fixture {
    _dir: TempDir,
    conn: Connection,
    run: Option<OpenRun>,
    seq: u64,
}

impl Fixture {
    fn new() -> Self {
        let dir = TempDir::new().unwrap();
        let mut conn = open_writer(&dir.path().join("vault.db"), &DbKey([1; 32])).unwrap();
        schema::migrate(&mut conn).unwrap();
        Self { _dir: dir, conn, run: None, seq: 0 }
    }

    /// Adds a frame showing `lines` in `app`, with each line a row down the screen.
    fn frame(&mut self, t_ms: i64, app: &str, window: &str, lines: &[&str]) -> i64 {
        let tx = self.conn.transaction().unwrap();
        let chunk = ChunkInfo {
            uuid: [7; 16],
            display_uuid: [8; 16],
            width: 100,
            height: 100,
            path: "chunks/x".to_owned(),
        };
        project::apply_one(
            &tx,
            &LoggedFrame {
                chunk,
                seq: self.seq,
                offset: 0,
                len: 0,
                t_ms,
                is_sync: true,
                context: FrameContext {
                    bundle_id: Some(app.to_owned()),
                    window: Some(window.to_owned()),
                    ..FrameContext::default()
                },
            },
        )
        .unwrap();
        self.seq += 1;
        let (frame_id, segment_id, display_id): (i64, Option<i64>, i64) = tx
            .query_row(
                "SELECT id, segment_id, display_id FROM frame WHERE t_ms = ?1",
                params![t_ms],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();

        let prepared = prepare_lines(
            lines
                .iter()
                .enumerate()
                .map(|(row, text)| OcrLine {
                    text: (*text).to_owned(),
                    rect: Rect { x: 0.1, y: row as f32 * 0.1, width: 0.8, height: 0.05 },
                })
                .collect(),
            None,
        );
        let joins = self
            .run
            .as_ref()
            .is_some_and(|run| run.accepts(POLICY, segment_id, t_ms, &prepared));
        if !joins {
            self.run = Some(OpenRun::new(segment_id, display_id, t_ms, &prepared));
        }
        let run = self.run.as_mut().unwrap();
        let shown = run.add(t_ms, &prepared);
        let run_id = text::write_run(&tx, run).unwrap();
        text::write_frame_text(&tx, frame_id, run_id, &shown).unwrap();
        tx.commit().unwrap();
        frame_id
    }

    fn search(&self, query: &str) -> Page {
        self.search_with(query, Facets::default(), Order::Newest)
    }

    fn search_with(&self, query: &str, facets: Facets, order: Order) -> Page {
        let parsed = Query::parse(query).unwrap();
        let mut search = Search::new(&self.conn, parsed, facets, order).unwrap();
        search.next_page(&self.conn).unwrap()
    }
}

fn filler(prefix: &str, count: usize) -> Vec<String> {
    (0..count).map(|n| format!("{prefix} filler line number {n}")).collect()
}

fn refs(lines: &[String]) -> Vec<&str> {
    lines.iter().map(String::as_str).collect()
}

#[test]
fn a_word_on_screen_is_found_at_that_moment() {
    let mut f = Fixture::new();
    let frame = f.frame(1000, "com.app", "Notes", &["the quarterly budget", "something else"]);
    let page = f.search("budget ");
    assert_eq!(page.hits.len(), 1);
    assert_eq!(page.hits[0].frame_id, frame);
    assert_eq!(page.hits[0].snippet, "the quarterly budget");
    assert_eq!(page.hits[0].bundle_id.as_deref(), Some("com.app"));
    assert!(f.search("nonexistent ").hits.is_empty());
}

#[test]
fn the_highlight_is_narrowed_to_the_matching_word() {
    let mut f = Fixture::new();
    f.frame(1000, "com.app", "Notes", &["aaaa bbbb"]);
    let hit = &f.search("bbbb ").hits[0];
    let rect = hit.rects[0];
    // "bbbb" is the last 4 of 9 characters in a box from x = 0.1, width 0.8.
    assert!((rect.x - (0.1 + 0.8 * 5.0 / 9.0)).abs() < 0.001);
    assert!((rect.width - 0.8 * 4.0 / 9.0).abs() < 0.001);
    assert!((rect.y - 0.0).abs() < 0.001);
}

/// A run's document holds every line any of its frames showed. Terms on different
/// frames match the index but were never on screen together.
#[test]
fn terms_must_have_been_on_screen_at_the_same_moment() {
    let mut f = Fixture::new();
    let shared = filler("shared", 40);
    let mut first = shared.clone();
    first.push("alpha appears here".to_owned());
    let mut second = shared.clone();
    second.push("omega appears here".to_owned());
    f.frame(1000, "com.app", "Notes", &refs(&first));
    f.frame(3000, "com.app", "Notes", &refs(&second));

    let runs: i64 = f.conn.query_row("SELECT count(*) FROM text_run", [], |r| r.get(0)).unwrap();
    assert_eq!(runs, 1, "this test needs both frames in one run");

    assert_eq!(f.search("alpha ").hits.len(), 1);
    assert_eq!(f.search("omega ").hits.len(), 1);
    assert!(f.search("alpha omega ").hits.is_empty(), "a false match got through");
}

#[test]
fn the_right_frame_of_a_run_is_returned() {
    let mut f = Fixture::new();
    let shared = filler("shared", 40);
    let mut first = shared.clone();
    first.push("alpha".to_owned());
    let mut second = shared.clone();
    second.push("omega".to_owned());
    let frame_a = f.frame(1000, "com.app", "Notes", &refs(&first));
    let frame_b = f.frame(3000, "com.app", "Notes", &refs(&second));
    assert_eq!(f.search("alpha ").hits[0].frame_id, frame_a);
    assert_eq!(f.search("omega ").hits[0].frame_id, frame_b);
    // A term on both frames gets the latest moment.
    assert_eq!(f.search("shared ").hits[0].frame_id, frame_b);
}

#[test]
fn a_term_in_the_window_title_counts_for_every_frame() {
    let mut f = Fixture::new();
    f.frame(1000, "com.app", "Project Falcon", &["budget table"]);
    assert_eq!(f.search("falcon budget ").hits.len(), 1);
    assert_eq!(f.search("falcon ").hits[0].snippet, "Project Falcon");
}

#[test]
fn phrases_do_not_match_across_lines() {
    let mut f = Fixture::new();
    f.frame(1000, "com.app", "Notes", &["ends with alpha", "beta starts this"]);
    assert!(f.search("\"alpha beta\"").hits.is_empty());
    assert_eq!(f.search("alpha beta ").hits.len(), 1);
}

#[test]
fn searching_as_you_type_finds_partial_words() {
    let mut f = Fixture::new();
    f.frame(1000, "com.app", "Notes", &["international shipping"]);
    for typed in ["in", "inter", "internation", "international"] {
        assert_eq!(f.search(typed).hits.len(), 1, "{typed}");
    }
}

#[test]
fn inflected_german_and_cjk_text_are_found() {
    let mut f = Fixture::new();
    f.frame(1000, "com.a", "T", &["He was running", "Herr Müller wohnt in der Straße"]);
    f.frame(300_000, "com.b", "T", &["東京都に住んでいます"]);
    assert_eq!(f.search("runs ").hits.len(), 1);
    assert_eq!(f.search("muller ").hits.len(), 1);
    assert_eq!(f.search("strasse ").hits.len(), 1);
    assert_eq!(f.search("\"東京\"").hits.len(), 1);
}

#[test]
fn facets_limit_by_app_and_time() {
    let mut f = Fixture::new();
    f.frame(1000, "com.one", "A", &["needle in one"]);
    f.frame(500_000, "com.two", "B", &["needle in two"]);

    let by_app = Facets { bundle_ids: vec!["com.two".to_owned()], ..Facets::default() };
    let page = f.search_with("needle ", by_app, Order::Newest);
    assert_eq!(page.hits.len(), 1);
    assert_eq!(page.hits[0].bundle_id.as_deref(), Some("com.two"));

    let by_time = Facets { to_ms: Some(2000), ..Facets::default() };
    let page = f.search_with("needle ", by_time, Order::Newest);
    assert_eq!(page.hits.len(), 1);
    assert_eq!(page.hits[0].bundle_id.as_deref(), Some("com.one"));
}

/// A run can straddle the requested time, so its matching frame has to be in range.
#[test]
fn a_date_filter_applies_to_the_frame_rather_than_the_whole_run() {
    let mut f = Fixture::new();
    let shared = filler("shared", 40);
    let inside = f.frame(1000, "com.app", "N", &refs(&shared));
    let after = f.frame(3000, "com.app", "N", &refs(&shared));
    let early = Facets { to_ms: Some(2000), ..Facets::default() };
    assert_eq!(f.search_with("shared ", early, Order::Newest).hits[0].frame_id, inside);
    assert_eq!(f.search("shared ").hits[0].frame_id, after);
}

#[test]
fn the_starred_facet_returns_only_starred_moments() {
    let mut f = Fixture::new();
    let shared = filler("shared", 40);
    let starred = f.frame(1000, "com.app", "N", &refs(&shared));
    f.frame(3000, "com.app", "N", &refs(&shared));
    f.conn.execute("UPDATE frame SET is_starred = 1 WHERE id = ?1", params![starred]).unwrap();
    let only = Facets { starred_only: true, ..Facets::default() };
    let hits = f.search_with("shared ", only, Order::Newest).hits;
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].frame_id, starred);
}

#[test]
fn newest_order_returns_recent_moments_first() {
    let mut f = Fixture::new();
    for (index, t) in [1000, 400_000, 800_000].iter().enumerate() {
        f.frame(*t, &format!("com.app{index}"), "W", &[&format!("needle in {index}")]);
    }
    let times: Vec<i64> = f.search("needle ").hits.iter().map(|h| h.t_ms).collect();
    assert_eq!(times, [800_000, 400_000, 1000]);
}

#[test]
fn relevance_ranks_a_title_match_above_a_text_match() {
    let mut f = Fixture::new();
    f.frame(1000, "com.a", "Unrelated", &["falcon plus some other filler words here"]);
    f.frame(400_000, "com.b", "Project Falcon", &["more filler words without the term"]);
    let hits = f.search_with("falcon ", Facets::default(), Order::Relevance).hits;
    assert_eq!(hits[0].window.as_deref(), Some("Project Falcon"));
}

#[test]
fn identical_lines_in_later_runs_are_not_shown_twice() {
    let mut f = Fixture::new();
    f.frame(1000, "com.a", "W1", &["the same needle line"]);
    f.frame(400_000, "com.b", "W2", &["the same needle line"]);
    assert_eq!(f.search("needle ").hits.len(), 1);
}

#[test]
fn paging_returns_every_result_once_and_later_recordings_do_not_shift_it() {
    let mut f = Fixture::new();
    for n in 0..70 {
        let t = 1000 + n as i64 * 300_000;
        f.frame(t, &format!("com.app{n}"), "W", &[&format!("needle number {n}")]);
    }
    let parsed = Query::parse("needle ").unwrap();
    let mut search = Search::new(&f.conn, parsed, Facets::default(), Order::Newest).unwrap();

    let first = search.next_page(&f.conn).unwrap();
    assert_eq!(first.hits.len(), 30);
    assert!(first.has_more);

    // A new recording arrives mid-search.
    f.frame(90_000_000, "com.new", "W", &["needle brand new"]);

    let mut seen: Vec<i64> = first.hits.iter().map(|h| h.frame_id).collect();
    loop {
        let page = search.next_page(&f.conn).unwrap();
        seen.extend(page.hits.iter().map(|h| h.frame_id));
        if !page.has_more {
            break;
        }
    }
    assert_eq!(seen.len(), 70);
    let unique: std::collections::HashSet<_> = seen.iter().collect();
    assert_eq!(unique.len(), 70);
}

/// A small window makes common words fast, but older matches still have to be
/// reachable, or a word you search for could seem never to have appeared.
#[test]
fn matches_older_than_the_ranking_window_are_still_returned_once() {
    let mut f = Fixture::new();
    for n in 0..200 {
        let t = 1000 + n as i64 * 300_000;
        f.frame(t, &format!("com.app{n}"), "W", &[&format!("needle number {n}")]);
    }
    let parsed = Query::parse("needle ").unwrap();
    let mut search =
        Search::with_ranking_window(&f.conn, parsed, Facets::default(), Order::Relevance, 20).unwrap();

    let mut seen = Vec::new();
    loop {
        let page = search.next_page(&f.conn).unwrap();
        seen.extend(page.hits.iter().map(|h| h.frame_id));
        if !page.has_more {
            break;
        }
    }
    assert_eq!(seen.len(), 200, "every match should be reachable");
    let unique: std::collections::HashSet<_> = seen.iter().collect();
    assert_eq!(unique.len(), 200, "nothing should appear twice");
}

#[test]
fn a_rare_word_is_ranked_across_all_of_history() {
    let mut f = Fixture::new();
    // The title match is the oldest thing here, and it still ranks first.
    f.frame(1000, "com.old", "Falcon", &["more filler words without the term"]);
    for n in 1..30 {
        let t = 1000 + n as i64 * 300_000;
        f.frame(t, &format!("com.app{n}"), "W", &[&format!("falcon plus filler words here {n}")]);
    }
    let parsed = Query::parse("falcon ").unwrap();
    // The window is larger than the word's 30 matches, so all of them get ranked.
    let mut search =
        Search::with_ranking_window(&f.conn, parsed, Facets::default(), Order::Relevance, 100).unwrap();
    let page = search.next_page(&f.conn).unwrap();
    assert_eq!(page.hits[0].window.as_deref(), Some("Falcon"));
}

#[test]
fn query_syntax_in_a_search_is_harmless() {
    let mut f = Fixture::new();
    f.frame(1000, "com.a", "W", &["alpha OR beta NOT gamma"]);
    for typed in ["alpha OR", "NOT gamma", "col:alpha", "alpha*", "(alpha", "a\"b", "^alpha", "NEAR(alpha beta)"] {
        // These must return normally. Whether they match doesn't matter here.
        let _ = f.search(typed);
    }
}
