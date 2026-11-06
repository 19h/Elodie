//! Spike 0: does the storage stack the plan assumes actually work?
//!
//! These stay in the suite as regression tests. A dependency bump that changes
//! the crypto provider or breaks contentless deletion should fail here.

use elodie_store::{DbKey, open_reader, open_writer};
use elodie_text::LINE_SEPARATOR;
use rusqlite::{Connection, params};
use tempfile::TempDir;

const KEY: DbKey = DbKey([7; 32]);

const CREATE_FTS: &str = "CREATE VIRTUAL TABLE run_fts USING fts5(
    text, other, title,
    content='', contentless_delete=1,
    tokenize='elodie', prefix='2 3'
)";

fn db() -> (TempDir, Connection) {
    let dir = TempDir::new().unwrap();
    let conn = open_writer(&dir.path().join("test.db"), &KEY).unwrap();
    conn.execute_batch(CREATE_FTS).unwrap();
    (dir, conn)
}

fn insert(conn: &Connection, id: i64, text: &str) {
    conn.execute(
        "INSERT INTO run_fts(rowid, text, other, title) VALUES (?1, ?2, '', '')",
        params![id, text],
    )
    .unwrap();
}

fn search(conn: &Connection, query: &str) -> Vec<i64> {
    let mut stmt = conn
        .prepare("SELECT rowid FROM run_fts WHERE run_fts MATCH ?1 ORDER BY rowid")
        .unwrap();
    stmt.query_map([query], |row| row.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

#[test]
fn sqlcipher_uses_commoncrypto_so_openssl_is_not_needed() {
    let (_dir, conn) = db();
    let provider: String = conn.query_row("PRAGMA cipher_provider", [], |r| r.get(0)).unwrap();
    assert_eq!(provider, "commoncrypto");
}

#[test]
fn sqlite_is_new_enough_for_contentless_delete() {
    let (_dir, conn) = db();
    let version: String = conn.query_row("SELECT sqlite_version()", [], |r| r.get(0)).unwrap();
    let parts: Vec<u32> = version.split('.').map(|p| p.parse().unwrap()).collect();
    assert!(parts[0] > 3 || parts[1] >= 43, "SQLite {version} is too old");
}

#[test]
fn the_file_on_disk_is_encrypted() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("test.db");
    let conn = open_writer(&path, &KEY).unwrap();
    conn.execute_batch("CREATE TABLE secret(v); INSERT INTO secret VALUES ('needle-in-plaintext');")
        .unwrap();
    conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);").unwrap();
    drop(conn);

    let bytes = std::fs::read(&path).unwrap();
    assert!(!bytes.starts_with(b"SQLite format 3"));
    assert!(!bytes.windows(19).any(|w| w == b"needle-in-plaintext"));
}

#[test]
fn a_wrong_key_is_rejected() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("test.db");
    open_writer(&path, &KEY).unwrap().execute_batch("CREATE TABLE t(v);").unwrap();
    assert!(open_writer(&path, &DbKey([8; 32])).is_err());
}

#[test]
fn stems_match_whole_word_queries() {
    let (_dir, conn) = db();
    insert(&conn, 1, "the runner was running fast");
    assert_eq!(search(&conn, "runs"), [1]);
    assert_eq!(search(&conn, "running"), [1]);
    assert!(search(&conn, "walking").is_empty());
}

#[test]
fn prefix_queries_match_folded_words_that_stemming_would_miss() {
    let (_dir, conn) = db();
    insert(&conn, 1, "the runner was running fast");
    // "runnin" isn't a prefix of the stem "run", so this only works because
    // documents also index the folded form.
    assert_eq!(search(&conn, "\"runnin\"*"), [1]);
    assert_eq!(search(&conn, "\"ru\"*"), [1]);
    assert!(search(&conn, "\"walk\"*").is_empty());
}

#[test]
fn diacritics_fold_in_both_directions() {
    let (_dir, conn) = db();
    insert(&conn, 1, "Müller und Straße");
    assert_eq!(search(&conn, "muller"), [1]);
    assert_eq!(search(&conn, "müller"), [1]);
    assert_eq!(search(&conn, "strasse"), [1]);
}

#[test]
fn cjk_text_is_searchable_without_spaces() {
    let (_dir, conn) = db();
    insert(&conn, 1, "東京都に住んでいます");
    assert_eq!(search(&conn, "\"東京\""), [1]);
    assert_eq!(search(&conn, "\"京都\""), [1]);
    assert!(search(&conn, "\"大阪\"").is_empty());
}

#[test]
fn phrases_do_not_match_across_the_line_separator() {
    let (_dir, conn) = db();
    insert(&conn, 1, &format!("first alpha{LINE_SEPARATOR}beta last"));
    insert(&conn, 2, "alpha beta");
    assert_eq!(search(&conn, "\"alpha beta\""), [2]);
    assert_eq!(search(&conn, "alpha AND beta"), [1, 2]);
}

#[test]
fn urls_split_into_searchable_parts() {
    let (_dir, conn) = db();
    insert(&conn, 1, "see https://www.example.com/page_one");
    assert_eq!(search(&conn, "example"), [1]);
    assert_eq!(search(&conn, "\"example.com\""), [1]);
}

#[test]
fn contentless_rows_can_be_deleted() {
    let (_dir, conn) = db();
    insert(&conn, 1, "alpha");
    insert(&conn, 2, "alpha");
    conn.execute("DELETE FROM run_fts WHERE rowid = 1", []).unwrap();
    assert_eq!(search(&conn, "alpha"), [2]);
}

#[test]
fn contentless_rows_can_be_replaced() {
    // Runs grow as frames are added, so their documents get rewritten.
    let (_dir, conn) = db();
    insert(&conn, 1, "alpha");
    conn.execute(
        "INSERT OR REPLACE INTO run_fts(rowid, text, other, title) VALUES (1, 'beta', '', '')",
        [],
    )
    .unwrap();
    assert!(search(&conn, "alpha").is_empty());
    assert_eq!(search(&conn, "beta"), [1]);
}

#[test]
fn bm25_weights_rank_title_above_text_above_other() {
    let (_dir, conn) = db();
    let filler = "lorem ipsum dolor sit amet";
    for (id, text, other, title) in [
        (1, format!("needle {filler}"), filler.to_owned(), filler.to_owned()),
        (2, filler.to_owned(), format!("needle {filler}"), filler.to_owned()),
        (3, filler.to_owned(), filler.to_owned(), format!("needle {filler}")),
    ] {
        conn.execute(
            "INSERT INTO run_fts(rowid, text, other, title) VALUES (?1, ?2, ?3, ?4)",
            params![id, text, other, title],
        )
        .unwrap();
    }
    let mut stmt = conn
        .prepare(
            "SELECT rowid FROM run_fts WHERE run_fts MATCH 'needle'
             ORDER BY bm25(run_fts, 1.0, 0.3, 3.0)",
        )
        .unwrap();
    let order: Vec<i64> = stmt.query_map([], |r| r.get(0)).unwrap().map(Result::unwrap).collect();
    assert_eq!(order, [3, 1, 2]);
}

#[test]
fn a_reader_sees_committed_writes_and_can_use_the_tokenizer() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("test.db");
    let writer = open_writer(&path, &KEY).unwrap();
    writer.execute_batch(CREATE_FTS).unwrap();
    insert(&writer, 1, "running");

    let reader = open_reader(&path, &KEY).unwrap();
    assert_eq!(search(&reader, "runs"), [1]);
    assert!(reader.execute_batch("INSERT INTO run_fts(rowid, text) VALUES (2, 'x')").is_err());
}

#[test]
fn the_index_survives_reopening() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("test.db");
    {
        let conn = open_writer(&path, &KEY).unwrap();
        conn.execute_batch(CREATE_FTS).unwrap();
        insert(&conn, 1, "persistent");
    }
    let conn = open_writer(&path, &KEY).unwrap();
    assert_eq!(search(&conn, "persistent"), [1]);
}
