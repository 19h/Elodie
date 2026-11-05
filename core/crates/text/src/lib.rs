//! Text processing shared by indexing and search.

pub mod tokenizer;

pub use tokenizer::{LINE_SEPARATOR, Mode, Token, tokenize};
