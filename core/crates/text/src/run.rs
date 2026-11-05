//! Groups consecutive frames that show nearly the same text.
//!
//! Most frames repeat almost all of the previous frame's text. Indexing each one
//! fully would write the same words to the index thousands of times a day. A run
//! holds the text once, and each frame only records which lines it shows and where.
//!
//! A run's document is the union of its frames' lines, so `A AND B` can match terms
//! that were never on screen at the same moment. Search re-checks hits against
//! individual frames to rule that out.

use std::collections::{HashMap, HashSet};

use crate::{LINE_SEPARATOR, PreparedLine};

/// When a frame stops belonging to the current run.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum RunPolicy {
    /// Keep going while the frame's lines overlap the run's first frame by at least
    /// this Jaccard similarity, adding any new lines to the document.
    Union { min_similarity: f32, max_age_ms: i64 },
    /// Keep going only while a frame has exactly the same lines as the first.
    Exact { max_age_ms: i64 },
    /// One run per frame. This is the baseline to compare the others against.
    PerFrame,
}

impl Default for RunPolicy {
    fn default() -> Self {
        RunPolicy::Union { min_similarity: 0.8, max_age_ms: 5 * 60 * 1000 }
    }
}

/// A line in a run's document.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunLine {
    pub text: String,
    pub is_front: bool,
}

/// A run that can still accept frames.
#[derive(Debug)]
pub struct OpenRun {
    pub id: Option<i64>,
    pub segment_id: Option<i64>,
    pub display_id: i64,
    pub t_first: i64,
    pub t_last: i64,
    pub lines: Vec<RunLine>,
    index: HashMap<u64, u32>,
    anchor: HashSet<u64>,
    /// Whether the document has changed since it was last written.
    pub document_dirty: bool,
}

/// A line a frame shows: its number in the run, and where it is.
pub type FrameLine = (u32, crate::Rect);

impl OpenRun {
    /// Starts a run from its first frame's lines. They set the anchor.
    pub fn new(segment_id: Option<i64>, display_id: i64, t: i64, lines: &[PreparedLine]) -> Self {
        Self {
            id: None,
            segment_id,
            display_id,
            t_first: t,
            t_last: t,
            lines: Vec::with_capacity(lines.len()),
            index: HashMap::with_capacity(lines.len()),
            anchor: lines.iter().map(|line| line.key).collect(),
            document_dirty: true,
        }
    }

    /// Whether a frame can join this run.
    pub fn accepts(
        &self,
        policy: RunPolicy,
        segment_id: Option<i64>,
        t: i64,
        lines: &[PreparedLine],
    ) -> bool {
        if segment_id != self.segment_id || t < self.t_last {
            return false;
        }
        let keys: HashSet<u64> = lines.iter().map(|line| line.key).collect();
        match policy {
            RunPolicy::PerFrame => false,
            RunPolicy::Exact { max_age_ms } => {
                t - self.t_first < max_age_ms && keys == self.anchor
            }
            RunPolicy::Union { min_similarity, max_age_ms } => {
                t - self.t_first < max_age_ms && similarity(&self.anchor, &keys) >= min_similarity
            }
        }
    }

    /// Adds a frame, returning which lines it shows.
    pub fn add(&mut self, t: i64, lines: &[PreparedLine]) -> Vec<FrameLine> {
        self.t_last = self.t_last.max(t);
        lines
            .iter()
            .map(|line| {
                let number = *self.index.entry(line.key).or_insert_with(|| {
                    self.lines.push(RunLine { text: line.text.clone(), is_front: line.is_front });
                    self.document_dirty = true;
                    (self.lines.len() - 1) as u32
                });
                (number, line.rect)
            })
            .collect()
    }

    /// The document's front and other text, for indexing.
    pub fn document(&self) -> (String, String) {
        let mut front = String::new();
        let mut other = String::new();
        for line in &self.lines {
            let column = if line.is_front { &mut front } else { &mut other };
            if !column.is_empty() {
                column.push(LINE_SEPARATOR);
            }
            column.push_str(&line.text);
        }
        (front, other)
    }
}

/// Jaccard similarity of two sets. Two empty sets count as the same.
pub fn similarity(a: &HashSet<u64>, b: &HashSet<u64>) -> f32 {
    if a.is_empty() && b.is_empty() {
        return 1.0;
    }
    let shared = a.intersection(b).count();
    shared as f32 / (a.len() + b.len() - shared) as f32
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{OcrLine, Rect, prepare_lines};

    fn lines(texts: &[&str]) -> Vec<PreparedLine> {
        prepare_lines(
            texts
                .iter()
                .map(|text| OcrLine { text: (*text).to_owned(), rect: Rect::default() })
                .collect(),
            None,
        )
    }

    fn numbered(range: std::ops::Range<u32>) -> Vec<String> {
        range.map(|n| format!("line {n}")).collect()
    }

    fn prepared(texts: &[String]) -> Vec<PreparedLine> {
        lines(&texts.iter().map(String::as_str).collect::<Vec<_>>())
    }

    const POLICY: RunPolicy = RunPolicy::Union { min_similarity: 0.8, max_age_ms: 300_000 };

    #[test]
    fn similar_frames_join_and_different_ones_do_not() {
        let first = prepared(&numbered(0..100));
        let run = OpenRun::new(Some(1), 1, 0, &first);
        // 5 lines scrolled away and 5 new: 95 shared of 105 total, or 0.90.
        assert!(run.accepts(POLICY, Some(1), 2000, &prepared(&numbered(5..105))));
        // 20 scrolled: 80 shared of 120, or 0.67.
        assert!(!run.accepts(POLICY, Some(1), 2000, &prepared(&numbered(20..120))));
    }

    #[test]
    fn similarity_is_measured_from_the_first_frame_so_a_run_cannot_drift_forever() {
        let run = OpenRun::new(Some(1), 1, 0, &prepared(&numbered(0..100)));
        // Each step would be close to the previous frame, but this is far from the first.
        assert!(!run.accepts(POLICY, Some(1), 2000, &prepared(&numbered(50..150))));
    }

    #[test]
    fn a_new_segment_or_a_step_back_in_time_starts_a_new_run() {
        let first = prepared(&numbered(0..10));
        let run = OpenRun::new(Some(1), 1, 1000, &first);
        assert!(!run.accepts(POLICY, Some(2), 2000, &first));
        assert!(!run.accepts(POLICY, Some(1), 500, &first));
    }

    #[test]
    fn runs_end_when_they_get_too_old() {
        let first = prepared(&numbered(0..10));
        let run = OpenRun::new(Some(1), 1, 0, &first);
        assert!(run.accepts(POLICY, Some(1), 299_999, &first));
        assert!(!run.accepts(POLICY, Some(1), 300_000, &first));
    }

    #[test]
    fn the_exact_policy_allows_no_differences() {
        let policy = RunPolicy::Exact { max_age_ms: 300_000 };
        let first = prepared(&numbered(0..100));
        let run = OpenRun::new(Some(1), 1, 0, &first);
        assert!(run.accepts(policy, Some(1), 2000, &first));
        assert!(!run.accepts(policy, Some(1), 2000, &prepared(&numbered(1..101))));
    }

    #[test]
    fn the_per_frame_policy_never_joins() {
        let first = prepared(&numbered(0..10));
        let run = OpenRun::new(Some(1), 1, 0, &first);
        assert!(!run.accepts(RunPolicy::PerFrame, Some(1), 2000, &first));
    }

    #[test]
    fn repeated_lines_are_stored_once_and_new_ones_mark_the_document_dirty() {
        let first = lines(&["alpha", "beta"]);
        let mut run = OpenRun::new(Some(1), 1, 0, &first);
        let shown = run.add(0, &first);
        assert_eq!(shown.iter().map(|(n, _)| *n).collect::<Vec<_>>(), [0, 1]);
        assert_eq!(run.lines.len(), 2);

        run.document_dirty = false;
        run.add(2000, &lines(&["beta", "alpha"]));
        assert!(!run.document_dirty, "nothing new, so nothing needs rewriting");

        let shown = run.add(4000, &lines(&["beta", "gamma"]));
        assert!(run.document_dirty);
        assert_eq!(shown.iter().map(|(n, _)| *n).collect::<Vec<_>>(), [1, 2]);
        assert_eq!(run.t_last, 4000);
    }

    #[test]
    fn the_document_separates_lines_and_splits_front_from_other() {
        let mut prepared = lines(&["front one", "front two", "other one"]);
        prepared[2].is_front = false;
        let mut run = OpenRun::new(None, 1, 0, &prepared);
        run.add(0, &prepared);
        let (front, other) = run.document();
        assert_eq!(front, format!("front one{LINE_SEPARATOR}front two"));
        assert_eq!(other, "other one");
    }

    #[test]
    fn a_frame_with_no_text_is_like_another_frame_with_no_text() {
        let empty = lines(&[]);
        let run = OpenRun::new(None, 1, 0, &empty);
        assert!(run.accepts(POLICY, None, 2000, &empty));
    }
}
