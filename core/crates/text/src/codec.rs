//! Compact storage for a run's lines and a frame's line placements.

use std::io::Result;

use crate::{Rect, RunLine, run::FrameLine};

const ZSTD_LEVEL: i32 = 3;

/// Compresses a run's lines. Each is stored as a flag byte, its text, and a newline.
/// Newlines can't occur in a line, because preparing a line removes them.
pub fn encode_lines(lines: &[RunLine]) -> Result<Vec<u8>> {
    let mut plain = String::with_capacity(lines.iter().map(|line| line.text.len() + 2).sum());
    for line in lines {
        plain.push(if line.is_front { 'F' } else { 'O' });
        plain.push_str(&line.text);
        plain.push('\n');
    }
    zstd::encode_all(plain.as_bytes(), ZSTD_LEVEL)
}

/// Decompresses a run's lines.
pub fn decode_lines(compressed: &[u8]) -> Result<Vec<RunLine>> {
    let plain = zstd::decode_all(compressed)?;
    let plain = String::from_utf8_lossy(&plain);
    Ok(plain
        .split_terminator('\n')
        .map(|entry| {
            let mut chars = entry.chars();
            let is_front = chars.next() == Some('F');
            RunLine { text: chars.as_str().to_owned(), is_front }
        })
        .collect())
}

fn to_scaled(value: f32) -> u16 {
    (value.clamp(0.0, 1.0) * f32::from(u16::MAX)).round() as u16
}

/// Compresses what a frame shows. Each line takes 12 bytes before compression,
/// with positions rounded to 1/65535 of the frame, far finer than a pixel.
pub fn encode_frame_lines(lines: &[FrameLine]) -> Result<Vec<u8>> {
    let mut plain = Vec::with_capacity(lines.len() * 12);
    for (number, rect) in lines {
        plain.extend_from_slice(&number.to_le_bytes());
        for value in [rect.x, rect.y, rect.width, rect.height] {
            plain.extend_from_slice(&to_scaled(value).to_le_bytes());
        }
    }
    zstd::encode_all(plain.as_slice(), ZSTD_LEVEL)
}

/// Decompresses what a frame shows.
pub fn decode_frame_lines(compressed: &[u8]) -> Result<Vec<FrameLine>> {
    let plain = zstd::decode_all(compressed)?;
    Ok(plain
        .chunks_exact(12)
        .map(|entry| {
            let number = u32::from_le_bytes([entry[0], entry[1], entry[2], entry[3]]);
            let value = |at: usize| {
                f32::from(u16::from_le_bytes([entry[at], entry[at + 1]])) / f32::from(u16::MAX)
            };
            (number, Rect { x: value(4), y: value(6), width: value(8), height: value(10) })
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn lines_round_trip() {
        let lines = vec![
            RunLine { text: "Hello, Wörld 東京".to_owned(), is_front: true },
            RunLine { text: "F starts with the flag letter".to_owned(), is_front: false },
            RunLine { text: String::new(), is_front: true },
        ];
        assert_eq!(decode_lines(&encode_lines(&lines).unwrap()).unwrap(), lines);
    }

    #[test]
    fn no_lines_round_trip() {
        assert!(decode_lines(&encode_lines(&[]).unwrap()).unwrap().is_empty());
        assert!(decode_frame_lines(&encode_frame_lines(&[]).unwrap()).unwrap().is_empty());
    }

    #[test]
    fn corrupt_data_is_an_error_rather_than_a_panic() {
        assert!(decode_lines(b"not zstd").is_err());
        assert!(decode_frame_lines(b"not zstd").is_err());
    }

    proptest! {
        #[test]
        fn frame_lines_round_trip_within_rounding(
            entries in proptest::collection::vec(
                (any::<u32>(), 0.0f32..=1.0, 0.0f32..=1.0, 0.0f32..=1.0, 0.0f32..=1.0),
                0..50,
            )
        ) {
            let lines: Vec<FrameLine> = entries
                .iter()
                .map(|&(n, x, y, width, height)| (n, Rect { x, y, width, height }))
                .collect();
            let decoded = decode_frame_lines(&encode_frame_lines(&lines).unwrap()).unwrap();
            prop_assert_eq!(decoded.len(), lines.len());
            for ((a_number, a), (b_number, b)) in lines.iter().zip(&decoded) {
                prop_assert_eq!(a_number, b_number);
                // Within half a step of 1/65535.
                for (x, y) in [(a.x, b.x), (a.y, b.y), (a.width, b.width), (a.height, b.height)] {
                    prop_assert!((x - y).abs() < 1.0 / 65535.0);
                }
            }
        }
    }
}
