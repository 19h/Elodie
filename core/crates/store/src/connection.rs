//! Opens encrypted database connections.

use std::fmt::Write as _;
use std::path::Path;

use rusqlite::{Connection, OpenFlags};

use crate::fts5;

/// A raw 256-bit database key.
///
/// A raw key skips SQLCipher's PBKDF2 derivation on each open. That's safe
/// because this key is random rather than derived from a password.
pub struct DbKey(pub [u8; 32]);

impl std::fmt::Debug for DbKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DbKey(redacted)")
    }
}

fn apply_key(conn: &Connection, key: &DbKey) -> rusqlite::Result<()> {
    let mut statement = String::with_capacity(90);
    statement.push_str("PRAGMA key = \"x'");
    for byte in key.0 {
        // Writing to a String can't fail.
        let _ = write!(statement, "{byte:02x}");
    }
    statement.push_str("'\";");
    conn.execute_batch(&statement)
}

fn configure(conn: &Connection) -> rusqlite::Result<()> {
    // SQLCipher only detects a wrong key on first read, so read before doing
    // anything else.
    conn.query_row("SELECT count(*) FROM sqlite_master", [], |_| Ok(()))?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = NORMAL;
         PRAGMA checkpoint_fullfsync = ON;
         PRAGMA foreign_keys = ON;
         PRAGMA busy_timeout = 5000;",
    )?;
    fts5::register_tokenizer(conn)
}

/// Opens the database for reading and writing, creating it if needed.
pub fn open_writer(path: &Path, key: &DbKey) -> rusqlite::Result<Connection> {
    let conn = Connection::open(path)?;
    apply_key(&conn, key)?;
    configure(&conn)?;
    Ok(conn)
}

/// Opens an existing database for reading.
pub fn open_reader(path: &Path, key: &DbKey) -> rusqlite::Result<Connection> {
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY
        | OpenFlags::SQLITE_OPEN_NO_MUTEX
        | OpenFlags::SQLITE_OPEN_URI;
    let conn = Connection::open_with_flags(path, flags)?;
    apply_key(&conn, key)?;
    conn.query_row("SELECT count(*) FROM sqlite_master", [], |_| Ok(()))?;
    conn.execute_batch("PRAGMA query_only = ON; PRAGMA busy_timeout = 5000;")?;
    fts5::register_tokenizer(&conn)?;
    Ok(conn)
}
