//! The Swift-facing API. Swift calls Rust and never the other way around.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use remind_store::DbKey;
use rusqlite::Connection;

uniffi::setup_scaffolding!();

/// An error the app can act on or show.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("the key must be 32 bytes, got {actual}")]
    InvalidKey { actual: u32 },
    #[error("storage failed: {message}")]
    Storage { message: String },
}

impl From<rusqlite::Error> for CoreError {
    fn from(error: rusqlite::Error) -> Self {
        CoreError::Storage { message: error.to_string() }
    }
}

/// What the running core was built with.
#[derive(Debug, uniffi::Record)]
pub struct CoreInfo {
    pub version: String,
    pub sqlite_version: String,
    pub cipher_provider: String,
}

/// An open vault.
#[derive(uniffi::Object)]
pub struct Core {
    db: Mutex<Connection>,
}

#[uniffi::export]
impl Core {
    /// Opens the vault at `path`, creating it if needed.
    #[uniffi::constructor]
    pub fn open(path: String, key: Vec<u8>) -> Result<Arc<Self>, CoreError> {
        let actual = u32::try_from(key.len()).unwrap_or(u32::MAX);
        let key: [u8; 32] = key.try_into().map_err(|_| CoreError::InvalidKey { actual })?;
        let db = remind_store::open_writer(&PathBuf::from(path), &DbKey(key))?;
        Ok(Arc::new(Self { db: Mutex::new(db) }))
    }

    pub fn info(&self) -> Result<CoreInfo, CoreError> {
        let db = self.db.lock().map_err(|_| CoreError::Storage {
            message: "the database lock was poisoned".to_owned(),
        })?;
        let sqlite_version = db.query_row("SELECT sqlite_version()", [], |r| r.get(0))?;
        let cipher_provider = db.query_row("PRAGMA cipher_provider", [], |r| r.get(0))?;
        Ok(CoreInfo {
            version: env!("CARGO_PKG_VERSION").to_owned(),
            sqlite_version,
            cipher_provider,
        })
    }

    /// Confirms async calls cross the boundary.
    pub async fn ping(&self) -> String {
        "pong".to_owned()
    }
}
