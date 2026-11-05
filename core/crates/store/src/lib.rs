//! Encrypted storage: connections, schema, and the projection from the log.

pub mod connection;
pub mod fts5;
pub mod project;
pub mod schema;
pub mod segment;
pub mod text;

pub use connection::{DbKey, open_reader, open_writer};
pub use project::{ChunkInfo, LoggedFrame};
pub use segment::FrameContext;
