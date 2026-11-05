//! Finds query terms in a line of text.
//!
//! The index can't report where a match is, because it's contentless. So lines get
//! tokenised again here, with the same tokenizer the index used.

use remind_text::{Mode, tokenize};

use crate::QueryTerm;

/// Where a term matched, as a byte range of the line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TermMatch {
    pub start: usize,
    pub end: usize,
}

/// A position in a line, which can hold both a word's folded form and its stem.
#[derive(Debug, Default)]
struct Position {
    forms: Vec<String>,
    start: usize,
    end: usize,
}

fn positions_of(line: &str) -> Vec<Position> {
    let mut positions: Vec<Position> = Vec::new();
    tokenize(line, Mode::Document, |token| {
        if token.colocated {
            if let Some(last) = positions.last_mut() {
                last.forms.push(token.text.to_owned());
            }
        } else {
            positions.push(Position {
                forms: vec![token.text.to_owned()],
                start: token.start,
                end: token.end,
            });
        }
        true
    });
    positions
}

/// Every place a term appears in a line.
pub fn find_in_line(line: &str, term: &QueryTerm) -> Vec<TermMatch> {
    let positions = positions_of(line);
    let count = term.tokens.len();
    if count == 0 || positions.len() < count {
        return Vec::new();
    }
    let mut matches = Vec::new();
    for start in 0..=(positions.len() - count) {
        let all_match = term.tokens.iter().enumerate().all(|(offset, token)| {
            let is_last = offset == count - 1;
            positions[start + offset].forms.iter().any(|form| {
                if term.prefix && is_last { form.starts_with(token) } else { form == token }
            })
        });
        if all_match {
            matches.push(TermMatch {
                start: positions[start].start,
                end: positions[start + count - 1].end,
            });
        }
    }
    matches
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Query;

    fn find<'a>(line: &'a str, query: &str) -> Vec<&'a str> {
        let parsed = Query::parse(query).unwrap();
        find_in_line(line, &parsed.terms[0]).iter().map(|m| &line[m.start..m.end]).collect()
    }

    #[test]
    fn stems_match_inflected_words() {
        assert_eq!(find("She was running fast", "runs "), ["running"]);
    }

    #[test]
    fn prefixes_match_word_starts_only() {
        assert_eq!(find("the runner reruns", "run"), ["runner"]);
    }

    #[test]
    fn phrases_need_adjacent_words_in_order() {
        assert_eq!(find("quarterly budget review", "\"quarterly budget\""), ["quarterly budget"]);
        assert!(find("budget quarterly review", "\"quarterly budget\"").is_empty());
        assert!(find("quarterly draft budget", "\"quarterly budget\"").is_empty());
    }

    #[test]
    fn matching_folds_like_the_index_does() {
        assert_eq!(find("Herr MÜLLER spricht", "muller "), ["MÜLLER"]);
        assert_eq!(find("die Straße", "strasse "), ["Straße"]);
    }

    #[test]
    fn urls_match_on_their_parts() {
        assert_eq!(find("https://www.example.com/x", "example "), ["example"]);
        assert_eq!(find("https://www.example.com/x", "\"example.com\""), ["example.com"]);
    }

    #[test]
    fn cjk_matches_inside_a_run_of_characters() {
        assert_eq!(find("東京都に住む", "\"東京\""), ["東京"]);
    }

    #[test]
    fn every_occurrence_is_found() {
        assert_eq!(find("note notes noted", "note "), ["note", "notes", "noted"]);
    }

    #[test]
    fn no_match_returns_nothing() {
        assert!(find("hello world", "xyz").is_empty());
        assert!(find("", "xyz").is_empty());
    }
}
