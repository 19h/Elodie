//! What OCR produces, and the first steps of processing it.

use std::hash::{DefaultHasher, Hash, Hasher};

use unicode_normalization::UnicodeNormalization;

/// A rectangle as fractions of the frame, with the origin at the top left.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl Rect {
    pub fn area(&self) -> f32 {
        self.width.max(0.0) * self.height.max(0.0)
    }

    pub fn intersection_area(&self, other: &Rect) -> f32 {
        let left = self.x.max(other.x);
        let right = (self.x + self.width).min(other.x + other.width);
        let top = self.y.max(other.y);
        let bottom = (self.y + self.height).min(other.y + other.height);
        (right - left).max(0.0) * (bottom - top).max(0.0)
    }

    /// Builds a rectangle from the 16-bit form stored with a frame.
    pub fn from_scaled(scaled: [u16; 4]) -> Self {
        let scale = |value: u16| f32::from(value) / f32::from(u16::MAX);
        Self {
            x: scale(scaled[0]),
            y: scale(scaled[1]),
            width: scale(scaled[2]),
            height: scale(scaled[3]),
        }
    }
}

/// One piece of text OCR found.
#[derive(Clone, Debug, PartialEq)]
pub struct OcrLine {
    pub text: String,
    pub rect: Rect,
}

/// A line ready to go into a run.
#[derive(Clone, Debug, PartialEq)]
pub struct PreparedLine {
    pub text: String,
    /// Equal for lines that read the same after normalising.
    pub key: u64,
    pub rect: Rect,
    /// Whether this is in the front window. Front text ranks higher in search.
    pub is_front: bool,
}

/// The identity of a line of text, ignoring case and spacing differences that
/// OCR can introduce between frames.
pub fn line_key(text: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    let mut pending_space = false;
    let mut started = false;
    for c in text.nfkc().flat_map(char::to_lowercase) {
        if c.is_whitespace() {
            // Spacing at the start of a line says nothing about its text.
            pending_space = started;
        } else {
            if pending_space {
                ' '.hash(&mut hasher);
                pending_space = false;
            }
            c.hash(&mut hasher);
            started = true;
        }
    }
    hasher.finish()
}

/// Whether a line counts as being in the window: over half of it is inside.
fn is_inside(line: &Rect, window: &Rect) -> bool {
    let area = line.area();
    area > 0.0 && line.intersection_area(window) / area > 0.5
}

/// Prepares a frame's lines for a run, dropping any that are empty.
pub fn prepare_lines(lines: Vec<OcrLine>, front_window: Option<Rect>) -> Vec<PreparedLine> {
    lines
        .into_iter()
        .filter_map(|line| {
            let text = line.text.trim();
            if text.is_empty() {
                return None;
            }
            // Newlines separate lines in storage, and the separator is reserved.
            let text: String = text
                .chars()
                .map(|c| if c == '\n' || c == crate::LINE_SEPARATOR { ' ' } else { c })
                .collect();
            Some(PreparedLine {
                key: line_key(&text),
                is_front: front_window.is_none_or(|window| is_inside(&line.rect, &window)),
                text,
                rect: line.rect,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(x: f32, y: f32, width: f32, height: f32) -> Rect {
        Rect { x, y, width, height }
    }

    fn line(text: &str, r: Rect) -> OcrLine {
        OcrLine { text: text.to_owned(), rect: r }
    }

    #[test]
    fn keys_ignore_case_and_spacing() {
        assert_eq!(line_key("Hello  World"), line_key("hello world"));
        assert_eq!(line_key(" hello world "), line_key("hello world"));
        assert_ne!(line_key("hello world"), line_key("helloworld"));
        assert_ne!(line_key("hello"), line_key("goodbye"));
    }

    #[test]
    fn keys_treat_equivalent_unicode_as_the_same() {
        assert_eq!(line_key("caf\u{00E9}"), line_key("cafe\u{0301}"));
    }

    #[test]
    fn a_line_mostly_inside_the_window_is_front() {
        let window = rect(0.0, 0.0, 0.5, 1.0);
        let lines = prepare_lines(
            vec![
                line("inside", rect(0.1, 0.1, 0.1, 0.1)),
                line("mostly in", rect(0.45, 0.2, 0.08, 0.1)),
                line("mostly out", rect(0.48, 0.3, 0.1, 0.1)),
                line("outside", rect(0.7, 0.1, 0.1, 0.1)),
            ],
            Some(window),
        );
        let front: Vec<bool> = lines.iter().map(|l| l.is_front).collect();
        assert_eq!(front, [true, true, false, false]);
    }

    #[test]
    fn with_no_front_window_everything_is_front() {
        let lines = prepare_lines(vec![line("a", rect(0.9, 0.9, 0.1, 0.1))], None);
        assert!(lines[0].is_front);
    }

    #[test]
    fn empty_lines_are_dropped() {
        let lines = prepare_lines(
            vec![line("", rect(0.0, 0.0, 0.1, 0.1)), line("   ", rect(0.0, 0.0, 0.1, 0.1))],
            None,
        );
        assert!(lines.is_empty());
    }

    #[test]
    fn reserved_characters_cannot_get_in() {
        let text = format!("a{}b\nc", crate::LINE_SEPARATOR);
        let lines = prepare_lines(vec![line(&text, rect(0.0, 0.0, 0.1, 0.1))], None);
        assert_eq!(lines[0].text, "a b c");
    }

    #[test]
    fn a_zero_area_line_is_not_inside_anything() {
        assert!(!is_inside(&rect(0.1, 0.1, 0.0, 0.0), &rect(0.0, 0.0, 1.0, 1.0)));
    }

    #[test]
    fn scaled_rects_cover_the_full_range() {
        let r = Rect::from_scaled([0, 0, u16::MAX, u16::MAX]);
        assert_eq!(r, rect(0.0, 0.0, 1.0, 1.0));
    }
}
