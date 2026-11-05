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
