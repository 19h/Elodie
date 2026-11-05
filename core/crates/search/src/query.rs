//! Turns what someone typed into a full-text query.

use remind_text::{Mode, tokenize};

/// One thing to look for: a word, or a quoted phrase.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QueryTerm {
    /// The tokens as the index stores them, in order.
    pub tokens: Vec<String>,
    /// Whether the last token matches as a prefix, for search as you type.
    pub prefix: bool,
    /// The text as typed, for building the full-text expression.
    raw: String,
}

/// A parsed search.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Query {
    pub terms: Vec<QueryTerm>,
    /// The expression for FTS5.
    pub expression: String,
}

fn tokens_of(text: &str, mode: Mode) -> Vec<String> {
    let mut tokens = Vec::new();
    tokenize(text, mode, |token| {
        tokens.push(token.text.to_owned());
        true
    });
    tokens
}

impl Query {
    /// Parses a search. Double quotes make a phrase, and everything else is split on
    /// spaces. The last word matches as a prefix unless a space follows it, because
    /// that's the word still being typed. Returns `None` if nothing is searchable.
    pub fn parse(input: &str) -> Option<Query> {
        let mut parts: Vec<(String, bool)> = Vec::new();
        let mut rest = input;
        loop {
            rest = rest.trim_start();
            if rest.is_empty() {
                break;
            }
            if let Some(quoted) = rest.strip_prefix('"') {
                match quoted.find('"') {
                    Some(end) => {
                        parts.push((quoted[..end].to_owned(), true));
                        rest = &quoted[end + 1..];
                    }
                    // An unclosed quote is still being typed.
                    None => {
                        parts.push((quoted.to_owned(), true));
                        rest = "";
                    }
                }
            } else {
                let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
                parts.push((rest[..end].to_owned(), false));
                rest = &rest[end..];
            }
        }

        let still_typing = !input.ends_with(char::is_whitespace);
        let last = parts.len().saturating_sub(1);
        let mut terms = Vec::with_capacity(parts.len());
        for (index, (raw, is_phrase)) in parts.into_iter().enumerate() {
            let prefix = index == last && still_typing && !is_phrase;
            let mode = if prefix { Mode::Prefix } else { Mode::Query };
            let tokens = tokens_of(&raw, mode);
            // Punctuation alone has nothing to match.
            if !tokens.is_empty() {
                terms.push(QueryTerm { tokens, prefix, raw });
            }
        }
        if terms.is_empty() {
            return None;
        }

        let expression = terms
            .iter()
            .map(|term| {
                let escaped = term.raw.replace('"', "\"\"");
                if term.prefix { format!("\"{escaped}\"*") } else { format!("\"{escaped}\"") }
            })
            .collect::<Vec<_>>()
            .join(" AND ");
        Some(Query { terms, expression })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_are_anded_and_the_last_one_is_a_prefix() {
        let query = Query::parse("meeting notes").unwrap();
        assert_eq!(query.expression, "\"meeting\" AND \"notes\"*");
        assert!(!query.terms[0].prefix);
        assert!(query.terms[1].prefix);
    }

    #[test]
    fn a_trailing_space_means_the_word_is_finished() {
        assert_eq!(Query::parse("notes ").unwrap().expression, "\"notes\"");
    }

    #[test]
    fn quotes_make_a_phrase() {
        let query = Query::parse("\"quarterly budget\" review").unwrap();
        assert_eq!(query.expression, "\"quarterly budget\" AND \"review\"*");
        assert_eq!(query.terms[0].tokens, ["quarter", "budget"]);
    }

    #[test]
    fn an_unclosed_quote_is_still_a_phrase() {
        assert_eq!(Query::parse("\"quarterly bud").unwrap().expression, "\"quarterly bud\"");
    }

    #[test]
    fn query_terms_are_stemmed_but_prefixes_are_not() {
        let query = Query::parse("running runnin").unwrap();
        assert_eq!(query.terms[0].tokens, ["run"]);
        assert_eq!(query.terms[1].tokens, ["runnin"]);
    }

    #[test]
    fn nothing_searchable_gives_none() {
        for input in ["", "   ", "...", "\"\"", "!!! ???"] {
            assert_eq!(Query::parse(input), None, "{input:?}");
        }
    }

    #[test]
    fn punctuation_only_terms_are_skipped_but_the_rest_still_search() {
        assert_eq!(Query::parse("hello ... ").unwrap().expression, "\"hello\"");
    }

    /// Anything typed must be safe to hand to FTS5, whose query language treats
    /// these as operators when they aren't quoted.
    #[test]
    fn query_syntax_in_the_input_stays_literal() {
        for input in ["a OR b", "NOT x", "col:x", "x*", "(y)", "a\"b", "^z", "x + y", "NEAR(a b)"] {
            assert!(Query::parse(input).is_some(), "{input:?}");
        }
        // A quote inside a word stays literal, escaped so it can't end the string.
        assert_eq!(Query::parse("a\"b").unwrap().expression, "\"a\"\"b\"*");
    }
}
