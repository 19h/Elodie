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
         tokenize='elodie', prefix='2 3'
     );",
    // Version 3: deletion.
    "CREATE TABLE purge (path TEXT PRIMARY KEY);
     DROP TABLE tombstone;",
    // Version 4: what was said. Transcripts are searchable like screen text, and they
    // share `text_run` and `run_fts`. Audio itself isn't kept.
    "ALTER TABLE text_run ADD COLUMN kind INTEGER NOT NULL DEFAULT 0;

     CREATE TABLE transcript_line (
         run_id INTEGER NOT NULL REFERENCES text_run(id) ON DELETE CASCADE,
         line_no INTEGER NOT NULL,
         t_ms INTEGER NOT NULL,
         duration_ms INTEGER NOT NULL,
         source INTEGER NOT NULL,
         PRIMARY KEY (run_id, line_no)
     ) WITHOUT ROWID;
     CREATE INDEX transcript_line_time ON transcript_line(t_ms);

     CREATE TABLE transcript_word (
         id INTEGER PRIMARY KEY,
         run_id INTEGER NOT NULL REFERENCES text_run(id) ON DELETE CASCADE,
         line_no INTEGER NOT NULL,
         word TEXT NOT NULL,
         t_ms INTEGER NOT NULL,
         duration_ms INTEGER NOT NULL,
         confidence REAL NOT NULL,
         source INTEGER NOT NULL
     );
     CREATE INDEX transcript_word_run ON transcript_word(run_id, line_no);

     CREATE TABLE meeting (
         id INTEGER PRIMARY KEY,
         title TEXT,
         t_start INTEGER NOT NULL,
         t_end INTEGER,
         summary TEXT
     );
     CREATE INDEX meeting_time ON meeting(t_start);",
    // Version 5: frame IDs are never reused. Deleting the newest frames would otherwise free
    // their IDs for new frames, and anything still holding an old ID, such as a decoded
    // picture, would then show a deleted frame under a new one.
    "CREATE TABLE frame_id_floor (
         only_row INTEGER PRIMARY KEY CHECK (only_row = 1),
         floor INTEGER NOT NULL
     );
     INSERT INTO frame_id_floor(only_row, floor) VALUES (1, 0);",
    // Version 6: opening the timeline reads when every segment started and ended, to find
    // the stretches where nothing was recorded. With the end in the index, that doesn't have
    // to read whole rows, with their window titles and URLs, on the way past.
    "DROP INDEX segment_time;
     CREATE INDEX segment_time ON segment(display_id, t_start, t_end);",
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
        crate::fts5::register_tokenizer(&conn).unwrap();
        migrate(&mut conn).unwrap();
        migrate(&mut conn).unwrap();
        let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0)).unwrap();
        assert_eq!(version, current_version());
    }

    #[test]
    fn a_vault_from_before_the_span_index_keeps_its_segments_and_gains_the_index() {
        let mut conn = Connection::open_in_memory().unwrap();
        crate::fts5::register_tokenizer(&conn).unwrap();
        for migration in &MIGRATIONS[..5] {
            conn.execute_batch(migration).unwrap();
        }
        conn.pragma_update(None, "user_version", 5).unwrap();
        conn.execute("INSERT INTO display(id, uuid) VALUES (1, x'01')", []).unwrap();
        conn.execute("INSERT INTO segment(display_id, t_start, t_end) VALUES (1, 100, 200)", []).unwrap();

        migrate(&mut conn).unwrap();

        let span: (i64, i64) =
            conn.query_row("SELECT t_start, t_end FROM segment", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!(span, (100, 200));
        let plan: String = conn
            .query_row(
                "EXPLAIN QUERY PLAN SELECT t_start, t_end FROM segment WHERE display_id = 1 ORDER BY t_start",
                [],
                |r| r.get(3),
            )
            .unwrap();
        assert!(plan.contains("COVERING INDEX segment_time"), "{plan}");
    }
}
