//! Text processing shared by indexing and search.

pub mod codec;
pub mod ocr;
pub mod run;
pub mod tokenizer;

pub use ocr::{OcrLine, PreparedLine, Rect, prepare_lines};
pub use run::{OpenRun, RunLine, RunPolicy};
pub use tokenizer::{LINE_SEPARATOR, Mode, Token, tokenize};
