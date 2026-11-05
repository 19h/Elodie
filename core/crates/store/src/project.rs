//! Projects chunk log records into the database.
//!
//! Replaying a record has no further effect once it's applied, which is what
//! makes crash recovery simple: replay everything past `indexed_seq`.

use rusqlite::{OptionalExtension, Transaction, params};

use crate::segment::{self, Decision, FrameContext, OpenSegment};

/// A chunk, as first seen by the projector.
#[derive(Clone, Debug)]
pub struct ChunkInfo {
    pub uuid: [u8; 16],
    pub display_uuid: [u8; 16],
    pub width: u32,
    pub height: u32,
    pub path: String,
}

/// A record that has reached the log.
#[derive(Clone, Debug)]
pub struct LoggedFrame {
    pub chunk: ChunkInfo,
    pub seq: u64,
    pub offset: u64,
    pub len: u32,
    pub t_ms: i64,
    pub is_sync: bool,
    pub context: FrameContext,
}

fn display_id(tx: &Transaction<'_>, uuid: &[u8; 16]) -> rusqlite::Result<i64> {
    tx.execute("INSERT OR IGNORE INTO display(uuid) VALUES (?1)", params![uuid.as_slice()])?;
    tx.query_row("SELECT id FROM display WHERE uuid = ?1", params![uuid.as_slice()], |r| r.get(0))
}

/// Registers a chunk if it's new, and returns its row ID.
pub fn ensure_chunk(tx: &Transaction<'_>, chunk: &ChunkInfo) -> rusqlite::Result<i64> {
    if let Some(id) = tx
        .query_row("SELECT id FROM chunk WHERE uuid = ?1", params![chunk.uuid.as_slice()], |r| r.get(0))
        .optional()?
    {
        return Ok(id);
    }
    let display = display_id(tx, &chunk.display_uuid)?;
    tx.execute(
        "INSERT INTO chunk(uuid, display_id, width, height, path) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![chunk.uuid.as_slice(), display, chunk.width, chunk.height, chunk.path],
    )?;
    Ok(tx.last_insert_rowid())
}

fn latest_segment(
    tx: &Transaction<'_>,
    display: i64,
) -> rusqlite::Result<Option<(i64, OpenSegment)>> {
    tx.query_row(
        "SELECT id, t_start, t_end, bundle_id, window, url, profile
         FROM segment WHERE display_id = ?1
         ORDER BY t_start DESC, id DESC LIMIT 1",
        params![display],
        |r| {
            Ok((
                r.get(0)?,
                OpenSegment {
                    t_start: r.get(1)?,
                    t_end: r.get(2)?,
                    context: FrameContext {
                        bundle_id: r.get(3)?,
                        window: r.get(4)?,
                        url: r.get(5)?,
                        profile: r.get(6)?,
                    },
                },
            ))
        },
    )
    .optional()
}

fn start_segment(
    tx: &Transaction<'_>,
    display: i64,
    t: i64,
    t_end: i64,
    context: &FrameContext,
) -> rusqlite::Result<i64> {
    tx.execute(
        "INSERT INTO segment(display_id, bundle_id, window, url, profile, t_start, t_end)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![display, context.bundle_id, context.window, context.url, context.profile, t, t_end],
    )?;
    Ok(tx.last_insert_rowid())
}

fn assign_segment(
    tx: &Transaction<'_>,
    display: i64,
    t: i64,
    context: &FrameContext,
) -> rusqlite::Result<i64> {
    let latest = latest_segment(tx, display)?;
    let decision = segment::decide(latest.as_ref().map(|(_, s)| s), t, context);
    match (decision, latest) {
        (Decision::Extend { t_end, context }, Some((id, _))) => {
            tx.execute(
                "UPDATE segment SET t_end = ?2, window = ?3, url = ?4, profile = ?5 WHERE id = ?1",
                params![id, t_end, context.window, context.url, context.profile],
            )?;
            Ok(id)
        }
        (Decision::CloseAndStart { closed_at, t_end }, Some((id, _))) => {
            tx.execute("UPDATE segment SET t_end = ?2 WHERE id = ?1", params![id, closed_at])?;
            start_segment(tx, display, t, t_end, context)
        }
        (Decision::Start { t_end }, _) => start_segment(tx, display, t, t_end, context),
        // `decide` only extends or closes when given a segment.
        (Decision::Extend { t_end, .. } | Decision::CloseAndStart { t_end, .. }, None) => {
            start_segment(tx, display, t, t_end, context)
        }
    }
}

/// Applies one logged frame. Applying it again has no effect.
pub fn apply_one(tx: &Transaction<'_>, frame: &LoggedFrame) -> rusqlite::Result<()> {
    let chunk_id = ensure_chunk(tx, &frame.chunk)?;
    let (display, indexed): (i64, i64) = tx.query_row(
        "SELECT display_id, indexed_seq FROM chunk WHERE id = ?1",
        params![chunk_id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;

    // Already applied, so don't touch the segment again.
    let seq = frame.seq as i64;
    if seq <= indexed {
        return Ok(());
    }

    let segment_id = assign_segment(tx, display, frame.t_ms, &frame.context)?;
    tx.execute(
        "INSERT OR IGNORE INTO frame
             (t_ms, display_id, chunk_id, seq, offset, len, is_sync, segment_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            frame.t_ms,
            display,
            chunk_id,
            seq,
            frame.offset as i64,
            frame.len,
            frame.is_sync,
            segment_id
        ],
    )?;
    tx.execute(
        "UPDATE chunk SET
             indexed_seq = ?2,
             indexed_offset = ?3,
             t_min = min(coalesce(t_min, ?4), ?4),
             t_max = max(coalesce(t_max, ?4), ?4)
         WHERE id = ?1",
        params![chunk_id, seq, (frame.offset + u64::from(frame.len)) as i64, frame.t_ms],
    )?;
    Ok(())
}
