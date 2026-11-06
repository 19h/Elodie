//! What the timeline strip draws, and which periods have recordings.

use std::collections::HashMap;

use rusqlite::{Connection, params};

/// A stretch of time in one app. `app` indexes [`Timeline::apps`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Run {
    pub start_ms: i64,
    pub end_ms: i64,
    pub app: u32,
}

/// Runs for part of the timeline, simplified for how much space they'll get.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Timeline {
    /// Each app's bundle ID. Keeping them apart means runs stay small and colours
    /// only need looking up once per app.
    pub apps: Vec<Option<String>>,
    pub runs: Vec<Run>,
}

/// Gaps shorter than this are recording pauses too short to show.
const MIN_GAP_DIVISOR: i64 = 2;

/// Simplifies runs for drawing: anything shorter than `min_duration_ms` couldn't be
/// seen, so it's absorbed by its neighbour, and adjacent runs of the same app merge.
///
/// This works in one pass from the start, so the same input always gives the same
/// result, which keeps the strip from shimmering as it scrolls.
pub fn simplify(runs: &[Run], min_duration_ms: i64) -> Vec<Run> {
    let mut simplified: Vec<Run> = Vec::with_capacity(runs.len().min(4096));
    for run in runs {
        let Some(last) = simplified.last_mut() else {
            simplified.push(*run);
            continue;
        };
        let gap = run.start_ms - last.end_ms;
        let same_app = last.app == run.app;
        let small_gap = gap < (min_duration_ms / MIN_GAP_DIVISOR).max(1);
        let duration = run.end_ms - run.start_ms;
        let last_duration = last.end_ms - last.start_ms;

        if small_gap && same_app {
            last.end_ms = last.end_ms.max(run.end_ms);
        } else if small_gap && duration < min_duration_ms {
            // Too short to see, so it joins the run before it.
            last.end_ms = last.end_ms.max(run.end_ms);
        } else if small_gap && last_duration < min_duration_ms {
            // The run before was too short to see, so this one takes it over.
            last.end_ms = last.end_ms.max(run.end_ms);
            last.app = run.app;
        } else {
            simplified.push(*run);
        }
    }
    simplified
}

/// Loads runs that overlap a period on a display.
pub fn load(
    conn: &Connection,
    display_uuid: &[u8; 16],
    from_ms: i64,
    to_ms: i64,
    min_duration_ms: i64,
) -> rusqlite::Result<Timeline> {
    let mut statement = conn.prepare_cached(
        "SELECT s.t_start, s.t_end, s.bundle_id FROM segment s
         WHERE s.display_id = (SELECT id FROM display WHERE uuid = ?1)
           AND s.t_end >= ?2 AND s.t_start <= ?3
         ORDER BY s.t_start",
    )?;
    let mut apps: Vec<Option<String>> = Vec::new();
    let mut indices: HashMap<Option<String>, u32> = HashMap::new();
    let rows = statement.query_map(params![display_uuid.as_slice(), from_ms, to_ms], |r| {
        Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, Option<String>>(2)?))
    })?;
    let mut runs = Vec::new();
    for row in rows {
        let (start_ms, end_ms, bundle) = row?;
        let app = *indices.entry(bundle.clone()).or_insert_with(|| {
            apps.push(bundle);
            (apps.len() - 1) as u32
        });
        runs.push(Run { start_ms, end_ms, app });
    }
    Ok(Timeline { apps, runs: simplify(&runs, min_duration_ms) })
}

/// Which of the given periods have any recording, for dimming days and hours that
/// have nothing to show. Each is checked with one index lookup, so even a long list
/// stays fast on years of data.
pub fn active_periods(
    conn: &Connection,
    periods: &[(i64, i64)],
) -> rusqlite::Result<Vec<bool>> {
    let mut statement = conn.prepare_cached(
        "SELECT EXISTS (SELECT 1 FROM segment WHERE t_end >= ?1 AND t_start < ?2)",
    )?;
    periods
        .iter()
        .map(|(from, to)| statement.query_row(params![from, to], |r| r.get(0)))
        .collect()
}

/// Speech isn't tied to a display, so its segments share this reserved ID.
const AUDIO_DISPLAY: [u8; 16] = [0; 16];

/// The stretches with something recorded for a display, oldest first: its screen, and
/// anything said, which can go on while the screen stays still. Stretches closer together
/// than `min_gap_ms` count as one.
///
/// This reads every segment's span, so it runs over the index alone and never touches
/// the rows, which hold window titles and URLs.
pub fn recorded_periods(
    conn: &Connection,
    display_uuid: &[u8; 16],
    min_gap_ms: i64,
) -> rusqlite::Result<Vec<(i64, i64)>> {
    let mut statement = conn.prepare_cached(
        "SELECT t_start, t_end FROM segment
         WHERE display_id = (SELECT id FROM display WHERE uuid = ?1)
         UNION ALL
         SELECT t_start, t_end FROM segment
         WHERE display_id = (SELECT id FROM display WHERE uuid = ?2)
         ORDER BY 1",
    )?;
    let rows = statement.query_map(params![display_uuid.as_slice(), AUDIO_DISPLAY.as_slice()], |r| {
        Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))
    })?;
    let mut periods: Vec<(i64, i64)> = Vec::new();
    for row in rows {
        let (start, end) = row?;
        match periods.last_mut() {
            Some(last) if start - last.1 < min_gap_ms => last.1 = last.1.max(end),
            _ => periods.push((start, end)),
        }
    }
    Ok(periods)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(start_ms: i64, end_ms: i64, app: u32) -> Run {
        Run { start_ms, end_ms, app }
    }

    #[test]
    fn long_runs_are_left_alone() {
        let runs = [run(0, 1000, 0), run(1000, 2000, 1), run(2000, 3000, 0)];
        assert_eq!(simplify(&runs, 100), runs);
    }

    #[test]
    fn adjacent_runs_of_one_app_merge() {
        assert_eq!(simplify(&[run(0, 1000, 0), run(1000, 2000, 0)], 100), [run(0, 2000, 0)]);
    }

    #[test]
    fn a_blip_too_short_to_see_is_absorbed() {
        let simplified = simplify(&[run(0, 1000, 0), run(1000, 1010, 1), run(1010, 2000, 0)], 100);
        assert_eq!(simplified, [run(0, 2000, 0)]);
    }

    #[test]
    fn a_short_run_at_the_start_is_taken_over_by_the_next() {
        assert_eq!(simplify(&[run(0, 10, 1), run(10, 1000, 0)], 100), [run(0, 1000, 0)]);
    }

    #[test]
    fn real_gaps_stay_as_gaps() {
        let runs = [run(0, 1000, 0), run(5000, 6000, 0)];
        assert_eq!(simplify(&runs, 100), runs);
    }

    #[test]
    fn gaps_too_small_to_see_close_up() {
        assert_eq!(simplify(&[run(0, 1000, 0), run(1020, 2000, 0)], 100), [run(0, 2000, 0)]);
    }

    #[test]
    fn nothing_in_gives_nothing_out() {
        assert!(simplify(&[], 100).is_empty());
    }

    #[test]
    fn simplifying_never_loses_covered_time_or_goes_backward() {
        // Many short alternating runs, as a zoomed-out day would have.
        let runs: Vec<Run> =
            (0..2000).map(|i| run(i * 10, (i + 1) * 10, (i % 3) as u32)).collect();
        for minimum in [1, 50, 500, 5000, 100_000] {
            let simplified = simplify(&runs, minimum);
            assert_eq!(simplified.first().map(|r| r.start_ms), Some(0));
            assert_eq!(simplified.last().map(|r| r.end_ms), Some(20_000));
            for pair in simplified.windows(2) {
                assert!(pair[0].end_ms <= pair[1].start_ms);
            }
        }
    }

    #[test]
    fn zooming_out_produces_far_fewer_runs() {
        let runs: Vec<Run> =
            (0..20_000).map(|i| run(i * 100, (i + 1) * 100, (i % 5) as u32)).collect();
        assert!(simplify(&runs, 60_000).len() < 100);
    }
}

/// Time spent in one app during a period.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppTime {
    pub bundle_id: Option<String>,
    pub milliseconds: i64,
}

/// A long stretch of focus, for the day's outline.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActivityBlock {
    pub start_ms: i64,
    pub end_ms: i64,
    pub bundle_id: Option<String>,
    pub window: Option<String>,
    pub url: Option<String>,
}

/// A summary of what was recorded in a period.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Recap {
    pub total_active_ms: i64,
    /// Longest first.
    pub apps: Vec<AppTime>,
    /// Active milliseconds in each bucket of the period.
    pub activity: Vec<i64>,
    /// Stretches of at least `MIN_BLOCK_MS`, oldest first.
    pub blocks: Vec<ActivityBlock>,
}

/// Stretches shorter than this aren't worth listing on a day's outline.
const MIN_BLOCK_MS: i64 = 5 * 60 * 1000;

/// Summarises a period from its segments, working only from local data.
pub fn recap(
    conn: &Connection,
    from_ms: i64,
    to_ms: i64,
    bucket_ms: i64,
) -> rusqlite::Result<Recap> {
    let mut statement = conn.prepare_cached(
        "SELECT t_start, t_end, bundle_id, window, url FROM segment
         WHERE type = 0 AND t_end >= ?1 AND t_start <= ?2 ORDER BY t_start",
    )?;
    let rows = statement.query_map(params![from_ms, to_ms], |r| {
        Ok(ActivityBlock {
            start_ms: r.get(0)?,
            end_ms: r.get(1)?,
            bundle_id: r.get(2)?,
            window: r.get(3)?,
            url: r.get(4)?,
        })
    })?;

    let buckets = usize::try_from((to_ms - from_ms) / bucket_ms.max(1) + 1).unwrap_or(0);
    let mut summary = Recap { activity: vec![0; buckets], ..Recap::default() };
    let mut by_app: HashMap<Option<String>, i64> = HashMap::new();

    for row in rows {
        let block = row?;
        let start = block.start_ms.max(from_ms);
        let end = block.end_ms.min(to_ms);
        if end <= start {
            continue;
        }
        summary.total_active_ms += end - start;
        *by_app.entry(block.bundle_id.clone()).or_default() += end - start;

        let mut cursor = start;
        while cursor < end {
            let index = ((cursor - from_ms) / bucket_ms.max(1)) as usize;
            let bucket_end = from_ms + (index as i64 + 1) * bucket_ms.max(1);
            let stop = bucket_end.min(end);
            if let Some(slot) = summary.activity.get_mut(index) {
                *slot += stop - cursor;
            }
            cursor = stop;
        }
        if end - start >= MIN_BLOCK_MS {
            summary.blocks.push(ActivityBlock { start_ms: start, end_ms: end, ..block });
        }
    }

    summary.apps = by_app
        .into_iter()
        .map(|(bundle_id, milliseconds)| AppTime { bundle_id, milliseconds })
        .collect();
    // Ties break by name, so the order doesn't change between runs.
    summary.apps.sort_by(|a, b| {
        b.milliseconds.cmp(&a.milliseconds).then_with(|| a.bundle_id.cmp(&b.bundle_id))
    });
    Ok(summary)
}

#[cfg(test)]
mod period_tests {
    use super::*;
    use elodie_store::{DbKey, open_writer, schema};
    use tempfile::TempDir;

    const SCREEN: [u8; 16] = [1; 16];
    const OTHER_SCREEN: [u8; 16] = [2; 16];

    fn database() -> (TempDir, Connection) {
        let dir = TempDir::new().unwrap();
        let mut conn = open_writer(&dir.path().join("vault.db"), &DbKey([1; 32])).unwrap();
        schema::migrate(&mut conn).unwrap();
        for (id, uuid) in [(1, SCREEN), (2, OTHER_SCREEN), (3, AUDIO_DISPLAY)] {
            conn.execute("INSERT INTO display(id, uuid) VALUES (?1, ?2)", params![id, uuid.as_slice()])
                .unwrap();
        }
        (dir, conn)
    }

    fn segment(conn: &Connection, display: i64, kind: i64, start: i64, end: i64) {
        conn.execute(
            "INSERT INTO segment(display_id, type, t_start, t_end) VALUES (?1, ?2, ?3, ?4)",
            params![display, kind, start, end],
        )
        .unwrap();
    }

    #[test]
    fn a_long_gap_splits_what_was_recorded() {
        let (_dir, conn) = database();
        segment(&conn, 1, 0, 0, 100);
        segment(&conn, 1, 0, 40_100, 40_200);
        assert_eq!(recorded_periods(&conn, &SCREEN, 30).unwrap(), [(0, 100), (40_100, 40_200)]);
    }

    #[test]
    fn stretches_close_together_count_as_one() {
        let (_dir, conn) = database();
        segment(&conn, 1, 0, 0, 100);
        segment(&conn, 1, 0, 120, 200);
        segment(&conn, 1, 0, 200, 300);
        assert_eq!(recorded_periods(&conn, &SCREEN, 30).unwrap(), [(0, 300)]);
    }

    #[test]
    fn another_displays_recordings_dont_fill_a_gap() {
        let (_dir, conn) = database();
        segment(&conn, 1, 0, 0, 100);
        segment(&conn, 2, 0, 200, 900);
        segment(&conn, 1, 0, 1000, 1100);
        assert_eq!(recorded_periods(&conn, &SCREEN, 30).unwrap(), [(0, 100), (1000, 1100)]);
        assert_eq!(recorded_periods(&conn, &OTHER_SCREEN, 30).unwrap(), [(200, 900)]);
    }

    #[test]
    fn speech_counts_as_recorded_on_every_display() {
        let (_dir, conn) = database();
        segment(&conn, 1, 0, 0, 100);
        segment(&conn, 3, 1, 90, 950);
        segment(&conn, 1, 0, 1000, 1100);
        segment(&conn, 3, 1, 5000, 5100);
        assert_eq!(recorded_periods(&conn, &SCREEN, 100).unwrap(), [(0, 1100), (5000, 5100)]);
    }

    #[test]
    fn a_short_stretch_inside_a_longer_one_doesnt_shorten_it() {
        let (_dir, conn) = database();
        segment(&conn, 1, 0, 0, 1000);
        segment(&conn, 3, 1, 100, 200);
        segment(&conn, 1, 0, 5000, 5100);
        assert_eq!(recorded_periods(&conn, &SCREEN, 100).unwrap(), [(0, 1000), (5000, 5100)]);
    }

    #[test]
    fn nothing_recorded_gives_nothing() {
        let (_dir, conn) = database();
        assert!(recorded_periods(&conn, &SCREEN, 30).unwrap().is_empty());
        assert!(recorded_periods(&conn, &[9; 16], 30).unwrap().is_empty());
    }
}

#[cfg(test)]
mod recap_tests {
    use super::*;
    use elodie_store::{DbKey, open_writer, schema};
    use tempfile::TempDir;

    fn database() -> (TempDir, Connection) {
        let dir = TempDir::new().unwrap();
        let mut conn = open_writer(&dir.path().join("vault.db"), &DbKey([1; 32])).unwrap();
        schema::migrate(&mut conn).unwrap();
        conn.execute("INSERT INTO display(id, uuid) VALUES (1, x'00')", []).unwrap();
        (dir, conn)
    }

    fn segment(conn: &Connection, start: i64, end: i64, app: &str) {
        conn.execute(
            "INSERT INTO segment(display_id, bundle_id, window, t_start, t_end)
             VALUES (1, ?1, 'W', ?2, ?3)",
            params![app, start, end],
        )
        .unwrap();
    }

    const MINUTE: i64 = 60_000;
    const HOUR: i64 = 60 * MINUTE;

    #[test]
    fn totals_and_ranks_time_by_app() {
        let (_dir, conn) = database();
        segment(&conn, 0, 30 * MINUTE, "com.a");
        segment(&conn, 30 * MINUTE, 40 * MINUTE, "com.b");
        segment(&conn, 40 * MINUTE, 60 * MINUTE, "com.a");
        let summary = recap(&conn, 0, 2 * HOUR, HOUR).unwrap();
        assert_eq!(summary.total_active_ms, 60 * MINUTE);
        assert_eq!(summary.apps[0].bundle_id.as_deref(), Some("com.a"));
        assert_eq!(summary.apps[0].milliseconds, 50 * MINUTE);
        assert_eq!(summary.apps[1].milliseconds, 10 * MINUTE);
    }

    #[test]
    fn time_is_shared_between_the_buckets_it_spans() {
        let (_dir, conn) = database();
        segment(&conn, 30 * MINUTE, 90 * MINUTE, "com.a");
        let summary = recap(&conn, 0, 3 * HOUR, HOUR).unwrap();
        assert_eq!(summary.activity[0], 30 * MINUTE);
        assert_eq!(summary.activity[1], 30 * MINUTE);
        assert_eq!(summary.activity[2], 0);
    }

    #[test]
    fn a_segment_overlapping_the_edge_only_counts_inside_the_period() {
        let (_dir, conn) = database();
        segment(&conn, -30 * MINUTE, 30 * MINUTE, "com.a");
        let summary = recap(&conn, 0, HOUR, HOUR).unwrap();
        assert_eq!(summary.total_active_ms, 30 * MINUTE);
        assert_eq!(summary.blocks[0].start_ms, 0);
    }

    #[test]
    fn only_long_stretches_become_blocks() {
        let (_dir, conn) = database();
        segment(&conn, 0, 2 * MINUTE, "com.short");
        segment(&conn, 10 * MINUTE, 40 * MINUTE, "com.long");
        let summary = recap(&conn, 0, HOUR, HOUR).unwrap();
        assert_eq!(summary.blocks.len(), 1);
        assert_eq!(summary.blocks[0].bundle_id.as_deref(), Some("com.long"));
    }

    #[test]
    fn an_empty_period_is_empty() {
        let (_dir, conn) = database();
        let summary = recap(&conn, 0, HOUR, HOUR).unwrap();
        assert_eq!(summary.total_active_ms, 0);
        assert!(summary.apps.is_empty());
    }
}
