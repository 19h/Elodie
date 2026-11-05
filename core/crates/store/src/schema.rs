//! The database schema and its migrations.
//!
//! The database is a projection of the chunk log. Everything here except stars,
//! tombstones, and OCR text can be rebuilt by scanning the log.

use rusqlite::Connection;

/// Each entry upgrades the schema by one version and runs in one transaction.
/// Never edit a released migration. Add a new one instead.
const MIGRATIONS: &[&str] = &[
    // Version 1.
    "CREATE TABLE display (
         id INTEGER PRIMARY KEY,
         uuid BLOB NOT NULL UNIQUE
     );

     CREATE TABLE chunk (
         id INTEGER PRIMARY KEY,
         uuid BLOB NOT NULL UNIQUE,
         display_id INTEGER NOT NULL REFERENCES display(id),
         width INTEGER NOT NULL,
         height INTEGER NOT NULL,
         t_min INTEGER,
         t_max INTEGER,
         -- Relative to the vault root.
         path TEXT NOT NULL,
         -- Records below this are in the frame table. -1 means none are.
         indexed_seq INTEGER NOT NULL DEFAULT -1,
         -- Where the next unindexed record starts.
         indexed_offset INTEGER,
         sealed INTEGER NOT NULL DEFAULT 0
     );
     CREATE INDEX chunk_unsealed ON chunk(id) WHERE sealed = 0;

     CREATE TABLE segment (
         id INTEGER PRIMARY KEY,
         display_id INTEGER NOT NULL REFERENCES display(id),
         type INTEGER NOT NULL DEFAULT 0,
         bundle_id TEXT,
         window TEXT,
         url TEXT,
         profile TEXT,
         t_start INTEGER NOT NULL,
         t_end INTEGER NOT NULL
     );
     CREATE INDEX segment_time ON segment(display_id, t_start);
     CREATE INDEX segment_end ON segment(t_end);

     CREATE TABLE frame (
         id INTEGER PRIMARY KEY,
         t_ms INTEGER NOT NULL,
         display_id INTEGER NOT NULL REFERENCES display(id),
         chunk_id INTEGER NOT NULL REFERENCES chunk(id) ON DELETE CASCADE,
         seq INTEGER NOT NULL,
         offset INTEGER NOT NULL,
         len INTEGER NOT NULL,
         is_sync INTEGER NOT NULL,
         is_starred INTEGER NOT NULL DEFAULT 0,
         segment_id INTEGER REFERENCES segment(id),
         run_id INTEGER,
         ocr_state INTEGER NOT NULL DEFAULT 0,
         ocr_attempts INTEGER NOT NULL DEFAULT 0,
         UNIQUE (chunk_id, seq)
     );
     CREATE INDEX frame_time ON frame(display_id, t_ms);
     CREATE INDEX frame_ocr ON frame(ocr_state, t_ms) WHERE ocr_state IN (0, 2);
     CREATE INDEX frame_starred ON frame(t_ms) WHERE is_starred = 1;
     CREATE INDEX frame_segment ON frame(segment_id);

     CREATE TABLE tombstone (
         id INTEGER PRIMARY KEY,
         t_from INTEGER NOT NULL,
         t_to INTEGER NOT NULL,
         done INTEGER NOT NULL DEFAULT 0
     );",
    // Version 2: text.
    "ALTER TABLE frame ADD COLUMN front_rect BLOB;

     -- A run is consecutive frames in one segment that show nearly the same text.
     -- The rowid is shared with run_fts.
     CREATE TABLE text_run (
         id INTEGER PRIMARY KEY,
         segment_id INTEGER REFERENCES segment(id),
         display_id INTEGER NOT NULL REFERENCES display(id),
         t_first INTEGER NOT NULL,
         t_last INTEGER NOT NULL,
         -- Compressed lines, in the order first seen. A frame's line numbers index this.
         lines_z BLOB NOT NULL
     );
     CREATE INDEX text_run_time ON text_run(t_first);

     -- Which of its run's lines a frame shows, and where.
     CREATE TABLE frame_text (
         frame_id INTEGER PRIMARY KEY REFERENCES frame(id) ON DELETE CASCADE,
         run_id INTEGER NOT NULL REFERENCES text_run(id) ON DELETE CASCADE,
         lines_z BLOB NOT NULL
     ) WITHOUT ROWID;
     CREATE INDEX frame_text_run ON frame_text(run_id, frame_id);

     CREATE VIRTUAL TABLE run_fts USING fts5(
         text, other, title,
         content='', contentless_delete=1,
         tokenize='remind', prefix='2 3'
     );",
];

/// Brings the database up to the current schema.
pub fn migrate(conn: &mut Connection) -> rusqlite::Result<()> {
    let current: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    for (version, migration) in (1..).zip(MIGRATIONS).skip(current as usize) {
        let tx = conn.transaction()?;
        tx.execute_batch(migration)?;
        tx.pragma_update(None, "user_version", version)?;
        tx.commit()?;
    }
    Ok(())
}

/// The schema version this build expects.
pub fn current_version() -> i64 {
    MIGRATIONS.len() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrating_twice_changes_nothing() {
        let mut conn = Connection::open_in_memory().unwrap();
        migrate(&mut conn).unwrap();
        migrate(&mut conn).unwrap();
        let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0)).unwrap();
        assert_eq!(version, current_version());
    }
}
