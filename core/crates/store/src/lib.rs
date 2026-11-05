//! Encrypted storage: connections, schema, and queries.

pub mod connection;
pub mod fts5;

pub use connection::{DbKey, open_reader, open_writer};
