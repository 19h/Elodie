//! Finds moments by the words on screen.
//!
//! The index holds one document per text run, so a match only says that a run could
//! contain the answer. Each hit then gets re-checked against the run's individual
//! frames, to find a moment that actually showed every term and where they were.
//! That also removes false matches, such as two terms that were in the same run but
//! never on screen together.

mod matching;
mod query;
mod search;

pub use matching::{TermMatch, find_in_line};
pub use query::{Query, QueryTerm};
pub use search::{DEFAULT_RANKING_WINDOW, Facets, Hit, Order, Page, Search};

/// Errors while searching.
#[derive(Debug, thiserror::Error)]
pub enum SearchError {
    #[error(transparent)]
    Database(#[from] rusqlite::Error),
    #[error("stored text is corrupt: {0}")]
    Corrupt(#[from] std::io::Error),
}
