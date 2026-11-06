//! Runs searches against the database.

use std::collections::{HashSet, VecDeque};

use rayon::prelude::*;
use elodie_text::{Rect, RunLine, codec};
use rusqlite::{Connection, ToSql, params_from_iter};

use crate::matching::{TermMatch, find_in_line};
use crate::{Query, SearchError};

/// Only this many of the newest matches are ranked by relevance. Ranking costs time for
/// every match, and a common word could have millions. Words rare enough for relevance
/// to matter have fewer matches than this, so they're ranked across all of history, and
/// for very common words, recency is a good stand-in.
///
/// Measured at 800,000 frames: common-word first pages took 75 ms at p95 with this
/// value, against 353 ms with 100,000. Older matches stay reachable, because paging
/// continues past the window, newest first.
pub const DEFAULT_RANKING_WINDOW: i64 = 5_000;
const PAGE_SIZE: usize = 30;
/// Rows fetched per page, because re-checking can reject some.
const ROWS_PER_PAGE: i64 = 90;
/// The most frames of a run considered when looking for a moment to show.
const MAX_FRAMES_PER_RUN: i64 = 600;
const DEDUPE_LOOKBACK: usize = 20;
const DEDUPE_TOLERANCE: f32 = 0.01;

/// The order of results.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Order {
    #[default]
    Relevance,
    Newest,
}

/// Limits on what's searched.
#[derive(Clone, Debug, Default)]
pub struct Facets {
    pub bundle_ids: Vec<String>,
    pub from_ms: Option<i64>,
    pub to_ms: Option<i64>,
    pub starred_only: bool,
    /// Only what was said, rather than what was on screen.
    pub transcripts_only: bool,
}

/// A moment that matched.
#[derive(Clone, Debug, PartialEq)]
pub struct Hit {
    pub frame_id: i64,
    pub run_id: i64,
    pub t_ms: i64,
    /// Which display the frame is from. Something said has no display.
    pub display_uuid: Option<[u8; 16]>,
    pub bundle_id: Option<String>,
    pub window: Option<String>,
    pub url: Option<String>,
    /// Where the matches are in the frame.
    pub rects: Vec<Rect>,
    /// The line containing the first match.
    pub snippet: String,
    /// Whether this was said rather than shown.
    pub is_transcript: bool,
}

/// One page of results.
#[derive(Clone, Debug)]
pub struct Page {
    pub hits: Vec<Hit>,
    /// Whether another page might have results.
    pub has_more: bool,
}

/// A candidate run from the index, with what's needed to check it.
struct Candidate {
    run_id: i64,
    kind: i64,
    transcript_lines: Vec<(i64, i64)>,
    bundle_id: Option<String>,
    window: Option<String>,
    url: Option<String>,
    lines_z: Vec<u8>,
    frames: Vec<CandidateFrame>,
}

struct CandidateFrame {
    frame_id: i64,
    t_ms: i64,
    display_uuid: Option<[u8; 16]>,
    lines_z: Vec<u8>,
}

/// A search in progress. It keeps its place across pages, and later recordings can't
/// shift results that were already shown.
pub struct Search {
    query: Query,
    facets: Facets,
    order: Order,
    /// The newest run when the search began.
    snapshot: i64,
    /// The oldest run the relevance order will consider.
    floor: i64,
    offset: i64,
    /// Whether the ranked window has been used up, and older matches are next.
    past_window: bool,
    exhausted: bool,
    recent: Vec<(String, Rect)>,
    /// Hits fetched beyond the last page. Each fetch reads extra rows, because
    /// re-checking can reject some.
    buffered: VecDeque<Hit>,
}

impl Search {
    pub fn new(
        conn: &Connection,
        query: Query,
        facets: Facets,
        order: Order,
    ) -> Result<Self, SearchError> {
        Self::with_ranking_window(conn, query, facets, order, DEFAULT_RANKING_WINDOW)
    }

    /// Starts a search that ranks this many of the newest matches.
    pub fn with_ranking_window(
        conn: &Connection,
        query: Query,
        facets: Facets,
        order: Order,
        ranking_window: i64,
    ) -> Result<Self, SearchError> {
        let snapshot: i64 =
            conn.query_row("SELECT coalesce(max(id), 0) FROM text_run", [], |r| r.get(0))?;
        let floor = if order == Order::Relevance {
            // The rowid of the Nth newest match sets how far back ranking looks.
            conn.prepare_cached(
                "SELECT rowid FROM run_fts WHERE run_fts MATCH ?1 AND rowid <= ?2
                 ORDER BY rowid DESC LIMIT 1 OFFSET ?3",
            )?
            .query_row(rusqlite::params![query.expression, snapshot, ranking_window], |r| r.get(0))
            .unwrap_or(0)
        } else {
            0
        };
        Ok(Self {
            query,
            facets,
            order,
            snapshot,
            floor,
            offset: 0,
            past_window: false,
            exhausted: false,
            recent: Vec::new(),
            buffered: VecDeque::new(),
        })
    }

    /// Fetches the next page.
    pub fn next_page(&mut self, conn: &Connection) -> Result<Page, SearchError> {
        while self.buffered.len() < PAGE_SIZE && !self.exhausted {
            let candidates = self.fetch_candidates(conn)?;
            let fetched = candidates.len() as i64;
            self.offset += fetched;
            if fetched < ROWS_PER_PAGE {
                // Anything older than the ranked window comes next, newest first, so
                // nothing that matches ever becomes unreachable.
                if self.order == Order::Relevance && !self.past_window && self.floor > 0 {
                    self.past_window = true;
                    self.offset = 0;
                } else {
                    self.exhausted = true;
                }
            }

            // Decompressing and re-tokenising is the costly part, and each candidate
            // is independent. `par_iter` keeps the order.
            let terms = &self.query.terms;
            let facets = &self.facets;
            let resolved: Vec<Option<Hit>> = candidates
                .par_iter()
                .map(|candidate| resolve(candidate, terms, facets))
                .collect::<Result<_, SearchError>>()?;

            for hit in resolved.into_iter().flatten() {
                if !self.is_duplicate(&hit) {
                    self.buffered.push_back(hit);
                }
            }
        }
        let count = self.buffered.len().min(PAGE_SIZE);
        let hits = self.buffered.drain(..count).collect();
        Ok(Page { hits, has_more: !self.exhausted || !self.buffered.is_empty() })
    }

    /// Drops a hit showing the same line in about the same size of box as a recent
    /// one. Unchanged lines recur across runs, and repeats add nothing.
    fn is_duplicate(&mut self, hit: &Hit) -> bool {
        let rect = hit.rects.first().copied().unwrap_or_default();
        let repeated = self.recent.iter().rev().take(DEDUPE_LOOKBACK).any(|(snippet, other)| {
            snippet == &hit.snippet
                && (rect.width - other.width).abs() + (rect.height - other.height).abs()
                    < DEDUPE_TOLERANCE
        });
        if !repeated {
            self.recent.push((hit.snippet.clone(), rect));
        }
        repeated
    }

    fn fetch_candidates(&self, conn: &Connection) -> Result<Vec<Candidate>, SearchError> {
        // Each phase covers its own rows, so nothing appears twice.
        let (newest, oldest) = if self.past_window {
            (self.floor - 1, 0)
        } else {
            (self.snapshot, self.floor)
        };
        let mut parameters: Vec<Box<dyn ToSql>> = vec![
            Box::new(self.query.expression.clone()),
            Box::new(newest),
            Box::new(oldest),
        ];
        let mut clauses = String::new();

        if !self.facets.bundle_ids.is_empty() {
            let marks = vec!["?"; self.facets.bundle_ids.len()].join(",");
            clauses.push_str(&format!(" AND s.bundle_id IN ({marks})"));
            for id in &self.facets.bundle_ids {
                parameters.push(Box::new(id.clone()));
            }
        }
        if let Some(from) = self.facets.from_ms {
            clauses.push_str(" AND r.t_last >= ?");
            parameters.push(Box::new(from));
        }
        if let Some(to) = self.facets.to_ms {
            clauses.push_str(" AND r.t_first <= ?");
            parameters.push(Box::new(to));
        }
        if self.facets.transcripts_only {
            clauses.push_str(" AND r.kind = 1");
        }
        if self.facets.starred_only {
            clauses.push_str(
                " AND EXISTS (SELECT 1 FROM frame f WHERE f.run_id = r.id AND f.is_starred = 1)",
            );
        }
        let order = match self.order {
            Order::Relevance if !self.past_window => "bm25(run_fts, 1.0, 0.3, 3.0), run_fts.rowid DESC",
            _ => "run_fts.rowid DESC",
        };
        parameters.push(Box::new(ROWS_PER_PAGE));
        parameters.push(Box::new(self.offset));

        let sql = format!(
            "SELECT r.id, r.lines_z, s.bundle_id, s.window, s.url, r.kind
             FROM run_fts
             JOIN text_run r ON r.id = run_fts.rowid
             LEFT JOIN segment s ON s.id = r.segment_id
             WHERE run_fts MATCH ? AND run_fts.rowid <= ? AND run_fts.rowid >= ?{clauses}
             ORDER BY {order} LIMIT ? OFFSET ?"
        );
        let mut statement = conn.prepare(&sql)?;
        let mut candidates: Vec<Candidate> = statement
            .query_map(params_from_iter(parameters.iter()), |r| {
                Ok(Candidate {
                    run_id: r.get(0)?,
                    lines_z: r.get(1)?,
                    bundle_id: r.get(2)?,
                    window: r.get(3)?,
                    url: r.get(4)?,
                    kind: r.get(5)?,
                    transcript_lines: Vec::new(),
                    frames: Vec::new(),
                })
            })?
            .collect::<rusqlite::Result<_>>()?;

        let starred = if self.facets.starred_only { " AND f.is_starred = 1" } else { "" };
        let frames_sql = format!(
            "SELECT t.frame_id, f.t_ms, t.lines_z,
                    (SELECT uuid FROM display WHERE id = f.display_id)
             FROM frame_text t
             JOIN frame f ON f.id = t.frame_id
             WHERE t.run_id = ?1{starred} ORDER BY f.t_ms DESC LIMIT ?2"
        );
        let mut frames = conn.prepare_cached(&frames_sql)?;
        let mut said = conn.prepare_cached(
            "SELECT line_no, t_ms FROM transcript_line WHERE run_id = ?1 ORDER BY line_no",
        )?;
        for candidate in &mut candidates {
            if candidate.kind == 1 {
                candidate.transcript_lines = said
                    .query_map(rusqlite::params![candidate.run_id], |r| Ok((r.get(0)?, r.get(1)?)))?
                    .collect::<rusqlite::Result<_>>()?;
                continue;
            }
            candidate.frames = frames
                .query_map(rusqlite::params![candidate.run_id, MAX_FRAMES_PER_RUN], |r| {
                    Ok(CandidateFrame {
                        frame_id: r.get(0)?,
                        t_ms: r.get(1)?,
                        lines_z: r.get(2)?,
                        display_uuid: r
                            .get::<_, Option<Vec<u8>>>(3)?
                            .and_then(|uuid| <[u8; 16]>::try_from(uuid).ok()),
                    })
                })?
                .collect::<rusqlite::Result<_>>()?;
        }
        Ok(candidates)
    }
}

/// Narrows a line's rectangle to the matched part, assuming characters are about
/// equally wide. Vision only reports a box for the whole line, and this needs no
/// extra OCR work. The result is approximate for proportional fonts.
fn sub_rect(line: &str, rect: Rect, found: TermMatch) -> Rect {
    let total = line.chars().count().max(1) as f32;
    let before = line[..found.start].chars().count() as f32;
    let inside = line[found.start..found.end].chars().count() as f32;
    Rect {
        x: rect.x + rect.width * before / total,
        y: rect.y,
        width: rect.width * inside / total,
        height: rect.height,
    }
}

/// Finds a frame in the run that shows every term, or `None` if no frame does.
fn resolve(
    candidate: &Candidate,
    terms: &[crate::QueryTerm],
    facets: &Facets,
) -> Result<Option<Hit>, SearchError> {
    let lines: Vec<RunLine> = codec::decode_lines(&candidate.lines_z)?;
    let title = candidate.window.as_deref().unwrap_or("");

    // Which lines contain each term. A term in the window title counts as shown on
    // every frame in the run.
    let mut matched_lines: Vec<HashSet<u32>> = Vec::with_capacity(terms.len());
    let mut in_title: Vec<bool> = Vec::with_capacity(terms.len());
    let mut line_matches: Vec<Vec<(usize, TermMatch)>> = vec![Vec::new(); lines.len()];
    for (term_index, term) in terms.iter().enumerate() {
        let mut found = HashSet::new();
        for (number, line) in lines.iter().enumerate() {
            for hit in find_in_line(&line.text, term) {
                found.insert(number as u32);
                line_matches[number].push((term_index, hit));
            }
        }
        in_title.push(!find_in_line(title, term).is_empty());
        matched_lines.push(found);
    }

    if candidate.kind == 1 {
        return Ok(resolve_transcript(candidate, &lines, &matched_lines, facets));
    }

    for frame in &candidate.frames {
        if facets.from_ms.is_some_and(|from| frame.t_ms < from)
            || facets.to_ms.is_some_and(|to| frame.t_ms > to)
        {
            continue;
        }
        let shown = codec::decode_frame_lines(&frame.lines_z)?;
        let numbers: HashSet<u32> = shown.iter().map(|(number, _)| *number).collect();
        let all_shown = matched_lines
            .iter()
            .zip(&in_title)
            .all(|(found, title_has_it)| *title_has_it || !found.is_disjoint(&numbers));
        if !all_shown {
            continue;
        }

        let mut rects = Vec::new();
        let mut snippet = None;
        for (number, rect) in &shown {
            let Some(line) = lines.get(*number as usize) else { continue };
            for (_, found) in &line_matches[*number as usize] {
                rects.push(sub_rect(&line.text, *rect, *found));
                if snippet.is_none() {
                    snippet = Some(line.text.clone());
                }
            }
        }
        return Ok(Some(Hit {
            frame_id: frame.frame_id,
            run_id: candidate.run_id,
            t_ms: frame.t_ms,
            display_uuid: frame.display_uuid,
            bundle_id: candidate.bundle_id.clone(),
            window: candidate.window.clone(),
            url: candidate.url.clone(),
            rects,
            snippet: snippet.unwrap_or_else(|| title.to_owned()),
            is_transcript: false,
        }));
    }
    Ok(None)
}

/// A transcript has no frames, so a hit is the first line where a term was said. Every
/// term must have been said in this stretch of conversation.
fn resolve_transcript(
    candidate: &Candidate,
    lines: &[RunLine],
    matched_lines: &[HashSet<u32>],
    facets: &Facets,
) -> Option<Hit> {
    if matched_lines.iter().any(HashSet::is_empty) {
        return None;
    }
    let first = matched_lines.iter().flatten().copied().min()?;
    let (_, t_ms) = candidate
        .transcript_lines
        .iter()
        .find(|(number, _)| *number == i64::from(first))?;
    if facets.from_ms.is_some_and(|from| *t_ms < from) || facets.to_ms.is_some_and(|to| *t_ms > to) {
        return None;
    }
    Some(Hit {
        display_uuid: None,
        frame_id: 0,
        run_id: candidate.run_id,
        t_ms: *t_ms,
        bundle_id: candidate.bundle_id.clone(),
        window: candidate.window.clone(),
        url: candidate.url.clone(),
        rects: Vec::new(),
        snippet: lines.get(first as usize)?.text.clone(),
        is_transcript: true,
    })
}
