//! Searches run on their own read connection, so they never block recording, and
//! one can be cancelled from another thread.

use std::sync::Mutex;

use remind_search::{Facets, Order, Page, Query, Search, SearchError};
use rusqlite::{Connection, InterruptHandle};

use crate::{Engine, EngineError, Result};

impl From<SearchError> for EngineError {
    fn from(error: SearchError) -> Self {
        match error {
            SearchError::Database(error) => EngineError::Database(error),
            SearchError::Corrupt(error) => EngineError::Corrupt(error.to_string()),
        }
    }
}

/// A search in progress, with its own connection.
pub struct SearchSession {
    state: Mutex<(Connection, Search)>,
    interrupt: InterruptHandle,
}

impl SearchSession {
    /// Fetches the next page.
    pub fn next_page(&self) -> Result<Page> {
        let mut state = self.state.lock().map_err(|_| EngineError::Stopped)?;
        let (conn, search) = &mut *state;
        Ok(search.next_page(conn)?)
    }

    /// Stops any query running on this session, from any thread.
    pub fn cancel(&self) {
        self.interrupt.interrupt();
    }
}

impl Engine {
    /// Starts a search.
    pub fn search(&self, query: Query, facets: Facets, order: Order) -> Result<SearchSession> {
        let conn = self.open_reader()?;
        let search = Search::new(&conn, query, facets, order)?;
        let interrupt = conn.get_interrupt_handle();
        Ok(SearchSession { state: Mutex::new((conn, search)), interrupt })
    }
}
