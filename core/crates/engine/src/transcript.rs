//! Stores what was said, searchable alongside what was on screen.

use elodie_store::segment::{self, Decision, FrameContext};
use elodie_text::transcript::{Speaker, Word, remove_echo};
use elodie_text::{LINE_SEPARATOR, RunLine, codec};
use rusqlite::{OptionalExtension, Transaction, params};

use crate::ocr::RunTracker;
use crate::writer::WriterMessage;
use crate::{Engine, EngineError, Result};

/// A new document starts after this long, so a search hit points somewhere useful in
/// a long meeting.
const MAX_DOCUMENT_MS: i64 = 5 * 60 * 1000;
/// A gap this long starts a new line.
const LINE_GAP_MS: i64 = 900;
/// Lines don't get longer than this many words.
const MAX_LINE_WORDS: usize = 30;

/// A word as it arrives from transcription.
#[derive(Clone, Debug)]
pub struct SpokenWord {
    pub text: String,
    pub t_ms: i64,
    pub duration_ms: i64,
    pub confidence: f32,
    /// Whether this came from the microphone.
    pub is_me: bool,
}

/// A line of a transcript.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TranscriptLine {
    pub text: String,
    pub t_ms: i64,
    pub duration_ms: i64,
    pub is_me: bool,
}

/// The transcript document being added to.
pub(crate) struct OpenTranscript {
    run_id: i64,
    t_first: i64,
    lines: Vec<RunLine>,
}

const fn source_code(is_me: bool) -> i64 {
    if is_me { 0 } else { 1 }
}

fn audio_display(tx: &Transaction<'_>) -> rusqlite::Result<i64> {
    // Transcripts aren't tied to a display, but segments need one, so they share a
    // reserved ID that no real display can have.
    let uuid = [0u8; 16];
    tx.execute("INSERT OR IGNORE INTO display(uuid) VALUES (?1)", params![uuid.as_slice()])?;
    tx.query_row("SELECT id FROM display WHERE uuid = ?1", params![uuid.as_slice()], |r| r.get(0))
}

fn ensure_segment(tx: &Transaction<'_>, t_ms: i64, title: Option<&str>) -> rusqlite::Result<i64> {
    let display = audio_display(tx)?;
    let latest: Option<(i64, i64)> = tx
        .query_row(
            "SELECT id, t_end FROM segment WHERE display_id = ?1 AND type = 1
             ORDER BY t_start DESC LIMIT 1",
            params![display],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    if let Some((id, t_end)) = latest {
        if t_ms < t_end + segment::SEGMENT_GAP_MS {
            tx.execute("UPDATE segment SET t_end = max(t_end, ?2) WHERE id = ?1", params![id, t_ms])?;
            return Ok(id);
        }
    }
    let context = FrameContext { window: title.map(str::to_owned), ..FrameContext::default() };
    // A lone segment always starts fresh here, so the decision is only for the span.
    let t_end = match segment::decide(None, t_ms, &context) {
        Decision::Start { t_end } => t_end,
        _ => t_ms,
    };
    tx.execute(
        "INSERT INTO segment(display_id, type, window, t_start, t_end) VALUES (?1, 1, ?2, ?3, ?4)",
        params![display, title, t_ms, t_end],
    )?;
    Ok(tx.last_insert_rowid())
}

/// Groups words into lines by speaker and pauses.
fn into_lines(words: Vec<Word>) -> Vec<Vec<Word>> {
    let mut lines: Vec<Vec<Word>> = Vec::new();
    for word in words {
        let starts_new = lines.last().is_none_or(|line: &Vec<Word>| {
            let Some(last) = line.last() else { return true };
            last.speaker != word.speaker
                || word.t_ms - (last.t_ms + last.duration_ms) > LINE_GAP_MS
                || line.len() >= MAX_LINE_WORDS
        });
        if starts_new {
            lines.push(vec![word]);
        } else if let Some(line) = lines.last_mut() {
            line.push(word);
        }
    }
    lines
}

/// Stores a batch of words, in one transaction with the document they join.
pub(crate) fn store(
    tx: &Transaction<'_>,
    tracker: &mut RunTracker,
    words: &[SpokenWord],
    title: Option<&str>,
) -> rusqlite::Result<()> {
    let mut sorted: Vec<Word> = words
        .iter()
        .map(|word| Word {
            text: word.text.clone(),
            t_ms: word.t_ms,
            duration_ms: word.duration_ms,
            confidence: word.confidence,
            speaker: if word.is_me { Speaker::Me } else { Speaker::Others },
        })
        .collect();
    sorted.sort_by_key(|word| word.t_ms);
    let cleaned = remove_echo(sorted);

    for line in into_lines(cleaned) {
        let Some(first) = line.first() else { continue };
        let (t_ms, is_me) = (first.t_ms, first.speaker == Speaker::Me);
        let t_end = line.last().map_or(t_ms, |w| w.t_ms + w.duration_ms);
        let text = line.iter().map(|w| w.text.as_str()).collect::<Vec<_>>().join(" ");
        let segment_id = ensure_segment(tx, t_end, title)?;

        let needs_new = tracker
            .transcript
            .as_ref()
            .is_none_or(|open| t_ms - open.t_first >= MAX_DOCUMENT_MS);
        if needs_new {
            let empty = codec::encode_lines(&[]).map_err(to_sql_error)?;
            tx.execute(
                "INSERT INTO text_run(segment_id, display_id, t_first, t_last, lines_z, kind)
                 SELECT ?1, display_id, ?2, ?2, ?3, 1 FROM segment WHERE id = ?1",
                params![segment_id, t_ms, empty],
            )?;
            tracker.transcript =
                Some(OpenTranscript { run_id: tx.last_insert_rowid(), t_first: t_ms, lines: Vec::new() });
        }
        let Some(open) = tracker.transcript.as_mut() else { continue };

        let line_no = open.lines.len() as i64;
        open.lines.push(RunLine { text, is_front: is_me });
        tx.execute(
            "INSERT INTO transcript_line(run_id, line_no, t_ms, duration_ms, source)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![open.run_id, line_no, t_ms, t_end - t_ms, source_code(is_me)],
        )?;
        for word in &line {
            tx.execute(
                "INSERT INTO transcript_word(run_id, line_no, word, t_ms, duration_ms, confidence, source)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    open.run_id,
                    line_no,
                    word.text,
                    word.t_ms,
                    word.duration_ms,
                    f64::from(word.confidence),
                    source_code(word.speaker == Speaker::Me)
                ],
            )?;
        }
        write_document(tx, open, t_end, title)?;
    }
    Ok(())
}

fn to_sql_error(error: std::io::Error) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(error))
}

fn write_document(
    tx: &Transaction<'_>,
    open: &OpenTranscript,
    t_last: i64,
    title: Option<&str>,
) -> rusqlite::Result<()> {
    let compressed = codec::encode_lines(&open.lines).map_err(to_sql_error)?;
    tx.execute(
        "UPDATE text_run SET lines_z = ?2, t_last = ?3 WHERE id = ?1",
        params![open.run_id, compressed, t_last],
    )?;
    let separator = LINE_SEPARATOR.to_string();
    let text = open.lines.iter().map(|l| l.text.as_str()).collect::<Vec<_>>().join(&separator);
    tx.execute(
        "INSERT OR REPLACE INTO run_fts(rowid, text, other, title) VALUES (?1, ?2, '', ?3)",
        params![open.run_id, text, title.unwrap_or("")],
    )?;
    Ok(())
}

/// Removes what was said in a time range from one transcript document.
pub(crate) fn remove_range(
    tx: &Transaction<'_>,
    run: i64,
    from_ms: i64,
    to_ms: i64,
) -> rusqlite::Result<()> {
    let removed = tx.execute(
        "DELETE FROM transcript_line WHERE run_id = ?1 AND t_ms >= ?2 AND t_ms <= ?3",
        params![run, from_ms, to_ms],
    )?;
    tx.execute(
        "DELETE FROM transcript_word WHERE run_id = ?1 AND t_ms >= ?2 AND t_ms <= ?3",
        params![run, from_ms, to_ms],
    )?;
    if removed == 0 {
        return Ok(());
    }

    let remaining: Vec<(i64, i64)> = {
        let mut statement = tx.prepare(
            "SELECT line_no, t_ms FROM transcript_line WHERE run_id = ?1 ORDER BY line_no",
        )?;
        statement.query_map(params![run], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<_>>()?
    };
    if remaining.is_empty() {
        tx.execute("DELETE FROM run_fts WHERE rowid = ?1", params![run])?;
        tx.execute("DELETE FROM text_run WHERE id = ?1", params![run])?;
        return Ok(());
    }

    let (compressed, title): (Vec<u8>, String) = tx.query_row(
        "SELECT r.lines_z, coalesce(s.window, '') FROM text_run r
         LEFT JOIN segment s ON s.id = r.segment_id WHERE r.id = ?1",
        params![run],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let lines = codec::decode_lines(&compressed).map_err(to_sql_error)?;
    let kept: Vec<RunLine> = remaining
        .iter()
        .filter_map(|(number, _)| lines.get(*number as usize).cloned())
        .collect();

    // Line numbers shift down, in order, so nothing collides.
    for (new_number, (old_number, _)) in remaining.iter().enumerate() {
        let new_number = new_number as i64;
        if new_number != *old_number {
            tx.execute(
                "UPDATE transcript_line SET line_no = ?3 WHERE run_id = ?1 AND line_no = ?2",
                params![run, old_number, new_number],
            )?;
            tx.execute(
                "UPDATE transcript_word SET line_no = ?3 WHERE run_id = ?1 AND line_no = ?2",
                params![run, old_number, new_number],
            )?;
        }
    }

    let compressed = codec::encode_lines(&kept).map_err(to_sql_error)?;
    tx.execute("UPDATE text_run SET lines_z = ?2 WHERE id = ?1", params![run, compressed])?;
    let separator = LINE_SEPARATOR.to_string();
    let text = kept.iter().map(|l| l.text.as_str()).collect::<Vec<_>>().join(&separator);
    tx.execute(
        "INSERT OR REPLACE INTO run_fts(rowid, text, other, title) VALUES (?1, ?2, '', ?3)",
        params![run, text, title],
    )?;
    Ok(())
}

impl Engine {
    /// Stores transcribed words. Words that were only the speakers' echo are dropped.
    pub fn append_transcript(&self, words: Vec<SpokenWord>, title: Option<String>) -> Result<()> {
        let (reply, response) = crossbeam_channel::bounded(1);
        self.writes
            .as_ref()
            .ok_or(EngineError::Stopped)?
            .send(WriterMessage::Transcript(words, title, reply))
            .map_err(|_| EngineError::Stopped)?;
        response.recv().map_err(|_| EngineError::Stopped)?
    }

    /// What was said in a period.
    pub fn transcript(&self, from_ms: i64, to_ms: i64) -> Result<Vec<TranscriptLine>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        let mut runs = reader.prepare_cached(
            "SELECT DISTINCT r.id, r.lines_z FROM text_run r
             JOIN transcript_line l ON l.run_id = r.id
             WHERE l.t_ms >= ?1 AND l.t_ms <= ?2 ORDER BY r.id",
        )?;
        let rows: Vec<(i64, Vec<u8>)> = runs
            .query_map(params![from_ms, to_ms], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;

        let mut result = Vec::new();
        let mut timed = reader.prepare_cached(
            "SELECT line_no, t_ms, duration_ms, source FROM transcript_line
             WHERE run_id = ?1 AND t_ms >= ?2 AND t_ms <= ?3 ORDER BY t_ms, line_no",
        )?;
        for (run, compressed) in rows {
            let lines = codec::decode_lines(&compressed)
                .map_err(|error| EngineError::Corrupt(error.to_string()))?;
            let entries: Vec<(i64, i64, i64, i64)> = timed
                .query_map(params![run, from_ms, to_ms], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
                })?
                .collect::<rusqlite::Result<_>>()?;
            for (number, t_ms, duration_ms, source) in entries {
                if let Some(line) = lines.get(number as usize) {
                    result.push(TranscriptLine {
                        text: line.text.clone(),
                        t_ms,
                        duration_ms,
                        is_me: source == 0,
                    });
                }
            }
        }
        result.sort_by_key(|line| line.t_ms);
        Ok(result)
    }

    /// Stored word timings for a period, as (word, start, duration, confidence).
    pub fn transcript_words(&self, from_ms: i64, to_ms: i64) -> Result<Vec<(String, i64, i64, f64)>> {
        let reader = self.reader.lock().map_err(|_| EngineError::Stopped)?;
        let mut statement = reader.prepare_cached(
            "SELECT word, t_ms, duration_ms, confidence FROM transcript_word
             WHERE t_ms >= ?1 AND t_ms <= ?2 ORDER BY t_ms, id",
        )?;
        let words = statement
            .query_map(params![from_ms, to_ms], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
            .collect::<rusqlite::Result<_>>()?;
        Ok(words)
    }
}
