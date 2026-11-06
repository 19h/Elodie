//! Stores text runs and what each frame shows.

use elodie_text::{OpenRun, codec, run::FrameLine};
use rusqlite::{Transaction, params};

/// OCR states of a frame.
pub mod ocr_state {
    /// Waiting for OCR.
    pub const PENDING: i64 = 0;
    pub const DONE: i64 = 1;
    /// Set aside while OCR is behind, to do when the machine is idle.
    pub const DEFERRED: i64 = 2;
    /// Gave up after repeated attempts.
    pub const FAILED: i64 = 3;
}

fn io_error(error: std::io::Error) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(error))
}

/// The window title for a segment, used as the document's title column.
fn segment_title(tx: &Transaction<'_>, segment_id: Option<i64>) -> rusqlite::Result<String> {
    let Some(segment_id) = segment_id else {
        return Ok(String::new());
    };
    tx.query_row(
        "SELECT coalesce(window, '') FROM segment WHERE id = ?1",
        params![segment_id],
        |r| r.get(0),
    )
}

/// Writes a run if its document has changed, and returns its ID.
pub fn write_run(tx: &Transaction<'_>, run: &mut OpenRun) -> rusqlite::Result<i64> {
    if let Some(id) = run.id {
        if !run.document_dirty {
            tx.execute("UPDATE text_run SET t_last = ?2 WHERE id = ?1", params![id, run.t_last])?;
            return Ok(id);
        }
    }

    let lines_z = codec::encode_lines(&run.lines).map_err(io_error)?;
    let id = match run.id {
        Some(id) => {
            tx.execute(
                "UPDATE text_run SET t_last = ?2, lines_z = ?3 WHERE id = ?1",
                params![id, run.t_last, lines_z],
            )?;
            id
        }
        None => {
            tx.execute(
                "INSERT INTO text_run(segment_id, display_id, t_first, t_last, lines_z)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![run.segment_id, run.display_id, run.t_first, run.t_last, lines_z],
            )?;
            tx.last_insert_rowid()
        }
    };

    let (text, other) = run.document();
    let title = segment_title(tx, run.segment_id)?;
    tx.execute(
        "INSERT OR REPLACE INTO run_fts(rowid, text, other, title) VALUES (?1, ?2, ?3, ?4)",
        params![id, text, other, title],
    )?;

    run.id = Some(id);
    run.document_dirty = false;
    Ok(id)
}

/// Records what a frame shows and marks its OCR as finished.
pub fn write_frame_text(
    tx: &Transaction<'_>,
    frame_id: i64,
    run_id: i64,
    lines: &[FrameLine],
) -> rusqlite::Result<()> {
    let compressed = codec::encode_frame_lines(lines).map_err(io_error)?;
    tx.execute(
        "INSERT OR REPLACE INTO frame_text(frame_id, run_id, lines_z) VALUES (?1, ?2, ?3)",
        params![frame_id, run_id, compressed],
    )?;
    tx.execute(
        "UPDATE frame SET run_id = ?2, ocr_state = ?3 WHERE id = ?1",
        params![frame_id, run_id, ocr_state::DONE],
    )?;
    Ok(())
}
