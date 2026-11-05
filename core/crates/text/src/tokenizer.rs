//! The one tokenizer used for both indexing and highlighting.
//!
//! The full-text table is contentless, so it can't report match offsets.
//! Highlights re-tokenise the stored text here, which only lines up if indexing
//! and highlighting share this code.
//!
//! Rules:
//! - Alphanumeric runs form words, so `example.com` and `foo_bar` split in two.
//! - Words are case-folded and stripped of diacritics, and `ß` becomes `ss`.
//! - In documents, each word is emitted in its folded form. If its English stem
//!   differs, the stem is emitted at the same position. Stemmed queries match
//!   the stem, and prefix queries match the folded form, because `runn*` could
//!   never match a stored `run`.
//! - CJK runs become overlapping bigrams, since they have no spaces to split on.
//! - [`LINE_SEPARATOR`] takes up a position, so a phrase can't match across two
//!   unrelated lines of a merged document.

use std::borrow::Cow;
use std::sync::OnceLock;

use rust_stemmers::{Algorithm, Stemmer};
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

/// Separates lines in a run's document. It's a private-use character, so it
/// can't occur in OCR output or in a typed query.
pub const LINE_SEPARATOR: char = '\u{E000}';

/// What the text is being tokenised for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Text being indexed: emits folded forms and their stems.
    Document,
    /// A complete query term: emits the stem only.
    Query,
    /// A query term ending in `*`: emits the folded form only.
    Prefix,
}

/// One emitted token. Offsets are UTF-8 byte offsets into the input.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Token<'a> {
    pub text: &'a str,
    pub start: usize,
    pub end: usize,
    /// Shares a position with the previous token.
    pub colocated: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Class {
    Word,
    Cjk,
    Separator,
    Line,
}

fn classify(c: char) -> Class {
    if c == LINE_SEPARATOR {
        Class::Line
    } else if is_cjk(c) {
        Class::Cjk
    } else if c.is_alphanumeric() || is_combining_mark(c) {
        Class::Word
    } else {
        Class::Separator
    }
}

fn is_cjk(c: char) -> bool {
    matches!(c as u32,
        0x1100..=0x11FF       // Hangul Jamo
        | 0x3040..=0x30FF     // Hiragana, Katakana
        | 0x3130..=0x318F     // Hangul compatibility Jamo
        | 0x3400..=0x4DBF     // Han extension A
        | 0x4E00..=0x9FFF     // Han
        | 0xAC00..=0xD7AF     // Hangul syllables
        | 0xF900..=0xFAFF     // Han compatibility
        | 0xFF66..=0xFF9D     // Halfwidth Katakana
        | 0x20000..=0x2FFFF   // Han extensions B and later
    )
}

fn stemmer() -> &'static Stemmer {
    static STEMMER: OnceLock<Stemmer> = OnceLock::new();
    STEMMER.get_or_init(|| Stemmer::create(Algorithm::English))
}

/// Case-folds a word and strips its diacritics.
fn fold(word: &str, out: &mut String) {
    out.clear();
    let simple = word.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit());
    if simple {
        out.push_str(word);
        return;
    }
    for c in word.nfd() {
        if is_combining_mark(c) {
            continue;
        }
        if c == 'ß' || c == 'ẞ' {
            out.push_str("ss");
            continue;
        }
        out.extend(c.to_lowercase());
    }
}

fn stem(folded: &str) -> Option<Cow<'_, str>> {
    // Stemming numbers or non-Latin words would only damage them.
    if folded.len() < 3 || !folded.bytes().all(|b| b.is_ascii_lowercase()) {
        return None;
    }
    Some(stemmer().stem(folded))
}

/// Calls `emit` for each token in `text`, stopping if it returns `false`.
pub fn tokenize(text: &str, mode: Mode, mut emit: impl FnMut(Token<'_>) -> bool) {
    let mut folded = String::new();
    let mut chars = text.char_indices().peekable();

    while let Some(&(start, c)) = chars.peek() {
        match classify(c) {
            Class::Separator => {
                chars.next();
            }
            Class::Line => {
                chars.next();
                let end = start + c.len_utf8();
                let token = Token { text: &text[start..end], start, end, colocated: false };
                if !emit(token) {
                    return;
                }
            }
            Class::Word => {
                let mut end = start;
                while let Some(&(i, c)) = chars.peek() {
                    if classify(c) != Class::Word {
                        break;
                    }
                    end = i + c.len_utf8();
                    chars.next();
                }
                fold(&text[start..end], &mut folded);
                if !emit_word(&folded, start, end, mode, &mut emit) {
                    return;
                }
            }
            Class::Cjk => {
                let mut run: Vec<(usize, usize)> = Vec::new();
                while let Some(&(i, c)) = chars.peek() {
                    if classify(c) != Class::Cjk {
                        break;
                    }
                    run.push((i, i + c.len_utf8()));
                    chars.next();
                }
                if !emit_cjk(text, &run, &mut emit) {
                    return;
                }
            }
        }
    }
}

fn emit_word(
    folded: &str,
    start: usize,
    end: usize,
    mode: Mode,
    emit: &mut impl FnMut(Token<'_>) -> bool,
) -> bool {
    if folded.is_empty() {
        return true;
    }
    match mode {
        Mode::Prefix => emit(Token { text: folded, start, end, colocated: false }),
        Mode::Query => {
            let stemmed = stem(folded);
            let text = stemmed.as_deref().unwrap_or(folded);
            emit(Token { text, start, end, colocated: false })
        }
        Mode::Document => {
            if !emit(Token { text: folded, start, end, colocated: false }) {
                return false;
            }
            match stem(folded) {
                Some(stemmed) if stemmed != folded => {
                    emit(Token { text: &stemmed, start, end, colocated: true })
                }
                _ => true,
            }
        }
    }
}

fn emit_cjk(
    text: &str,
    run: &[(usize, usize)],
    emit: &mut impl FnMut(Token<'_>) -> bool,
) -> bool {
    if let [(start, end)] = *run {
        return emit(Token { text: &text[start..end], start, end, colocated: false });
    }
    for pair in run.windows(2) {
        let (start, end) = (pair[0].0, pair[1].1);
        if !emit(Token { text: &text[start..end], start, end, colocated: false }) {
            return false;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn collect(text: &str, mode: Mode) -> Vec<(String, bool)> {
        let mut tokens = Vec::new();
        tokenize(text, mode, |t| {
            tokens.push((t.text.to_owned(), t.colocated));
            true
        });
        tokens
    }

    fn words(text: &str, mode: Mode) -> Vec<String> {
        collect(text, mode).into_iter().map(|(t, _)| t).collect()
    }

    #[test]
    fn splits_on_punctuation_like_urls_and_identifiers() {
        assert_eq!(words("example.com/foo_bar", Mode::Prefix), ["example", "com", "foo", "bar"]);
    }

    #[test]
    fn folds_case_and_diacritics() {
        assert_eq!(words("MÜLLER Crème Straße", Mode::Prefix), ["muller", "creme", "strasse"]);
    }

    #[test]
    fn documents_emit_folded_form_then_colocated_stem() {
        assert_eq!(
            collect("Running", Mode::Document),
            [("running".to_owned(), false), ("run".to_owned(), true)]
        );
    }

    #[test]
    fn a_word_equal_to_its_stem_is_emitted_once() {
        assert_eq!(collect("run", Mode::Document), [("run".to_owned(), false)]);
    }

    #[test]
    fn queries_stem_but_prefixes_do_not() {
        assert_eq!(words("Running", Mode::Query), ["run"]);
        assert_eq!(words("runnin", Mode::Prefix), ["runnin"]);
    }

    #[test]
    fn numbers_are_not_stemmed() {
        assert_eq!(words("2026 x86", Mode::Query), ["2026", "x86"]);
    }

    #[test]
    fn cjk_runs_become_bigrams_at_script_boundaries() {
        assert_eq!(words("abc東京都def", Mode::Prefix), ["abc", "東京", "京都", "def"]);
        assert_eq!(words("東", Mode::Prefix), ["東"]);
    }

    #[test]
    fn dakuten_survive_because_cjk_is_not_folded() {
        assert_eq!(words("がか", Mode::Prefix), ["がか"]);
    }

    #[test]
    fn line_separator_occupies_a_position() {
        let text = format!("hello{LINE_SEPARATOR}world");
        assert_eq!(words(&text, Mode::Prefix), ["hello", "\u{E000}", "world"]);
    }

    #[test]
    fn empty_and_separator_only_input_emit_nothing() {
        assert!(words("", Mode::Document).is_empty());
        assert!(words(" .,!? ", Mode::Document).is_empty());
    }

    #[test]
    fn stops_when_emit_returns_false() {
        let mut seen = 0;
        tokenize("a b c", Mode::Prefix, |_| {
            seen += 1;
            false
        });
        assert_eq!(seen, 1);
    }

    proptest! {
        #[test]
        fn offsets_are_ordered_char_boundaries(text in "\\PC{0,200}", mode in 0..3u8) {
            let mode = [Mode::Document, Mode::Query, Mode::Prefix][mode as usize];
            let mut last_start = 0;
            tokenize(&text, mode, |t| {
                assert!(text.is_char_boundary(t.start) && text.is_char_boundary(t.end));
                assert!(t.start < t.end && t.end <= text.len());
                assert!(t.start >= last_start);
                assert!(!t.text.is_empty());
                last_start = t.start;
                true
            });
        }
    }
}
