//! The encrypted, append-only chunk log.
//!
//! The log is the source of truth for recorded frames. The database is a
//! projection of it and can be rebuilt from it.
//!
//! # File format
//!
//! ```text
//! magic[8] | version u16 | reserved u16 | chunk_id[16] | header_len u32
//! AEAD(header_key_nonce, aad = the bytes above,
//!      { display_uuid[16], width u32, height u32, parameter_sets })
//! then records:
//! ct_len u32 | AEAD(nonce = seq, aad = chunk_id || seq,
//!                   { wall_ms i64, mono_ns u64, flags u32, meta_len u32, meta, sample })
//! ```
//!
//! Each chunk has its own key, derived from the master key and its random ID.
//! Records use their sequence number as the nonce, so **a chunk is never
//! reopened for writing**: resuming after a crash could repeat a nonce. A new
//! session always starts a new chunk, and recovery only truncates.
//!
//! Each record goes out in one `write`, so it survives SIGKILL. A torn record
//! fails authentication, and recovery stops there.

mod chunk;
mod key;

pub use chunk::{
    Appended, ChunkHeader, ChunkReader, ChunkWriter, MAX_RECORD_LEN, Record, RecordRef, Scan,
    ScanStart, ScannedRecord, flags, recover_tail,
};
pub use key::MasterKey;

/// Errors from reading or writing chunks.
#[derive(Debug, thiserror::Error)]
pub enum VaultError {
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("not a chunk file")]
    NotAChunk,
    #[error("unsupported chunk version {0}")]
    UnsupportedVersion(u16),
    #[error("authentication failed: the data is corrupt or the key is wrong")]
    Authentication,
    #[error("record of {0} bytes is too large")]
    RecordTooLarge(usize),
    #[error("record is malformed")]
    Malformed,
    #[error("the writer failed earlier and this chunk accepts no more records")]
    WriterFailed,
    #[error("couldn't get random bytes from the system")]
    Random,
}

impl VaultError {
    /// Whether this is the disk running out of space.
    pub fn is_disk_full(&self) -> bool {
        matches!(self, VaultError::Io(error) if error.raw_os_error() == Some(libc::ENOSPC))
    }
}

pub type Result<T> = std::result::Result<T, VaultError>;
