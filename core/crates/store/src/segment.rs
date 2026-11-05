//! Decides which segment a frame belongs to.
//!
//! A segment is a stretch of time in one app and window. It's what the timeline
//! draws, so these rules decide when the strip changes colour.

/// Frames further than this past a segment's end start a new one.
pub const SEGMENT_GAP_MS: i64 = 240_000;

/// How long a new segment initially covers: one capture interval.
pub const INITIAL_SPAN_MS: i64 = 2_000;

/// What was on screen for a frame.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FrameContext {
    pub bundle_id: Option<String>,
    pub window: Option<String>,
    pub url: Option<String>,
    pub profile: Option<String>,
}

/// The parts of a segment the rules depend on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OpenSegment {
    pub t_start: i64,
    pub t_end: i64,
    pub context: FrameContext,
}

/// What to do with a frame.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Extend the segment to `t_end` and fill in any metadata it was missing.
    Extend { t_end: i64, context: FrameContext },
    /// Leave the old segment as it is and start a new one.
    Start { t_end: i64 },
    /// End the old segment at this frame and start a new one.
    CloseAndStart { closed_at: i64, t_end: i64 },
}

/// Treats a missing value as compatible with anything. Browser URLs and window
/// titles often can't be read on a given tick, and that shouldn't split a segment.
fn compatible(a: &Option<String>, b: &Option<String>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => a == b,
        _ => true,
    }
}

fn fill(existing: &Option<String>, new: &Option<String>) -> Option<String> {
    existing.clone().or_else(|| new.clone())
}

/// Applies the segment rules to a frame at `t`.
pub fn decide(segment: Option<&OpenSegment>, t: i64, context: &FrameContext) -> Decision {
    let Some(segment) = segment else {
        return Decision::Start { t_end: t + INITIAL_SPAN_MS };
    };

    // Clock jumps can put a frame before its segment. A new segment keeps the
    // time ranges valid.
    if t < segment.t_start || t >= segment.t_end + SEGMENT_GAP_MS {
        return Decision::Start { t_end: t + INITIAL_SPAN_MS };
    }

    let matches = segment.context.bundle_id == context.bundle_id
        && compatible(&segment.context.window, &context.window)
        && compatible(&segment.context.url, &context.url)
        && compatible(&segment.context.profile, &context.profile);

    if matches {
        Decision::Extend {
            t_end: t.max(segment.t_end),
            context: FrameContext {
                bundle_id: segment.context.bundle_id.clone(),
                window: fill(&segment.context.window, &context.window),
                url: fill(&segment.context.url, &context.url),
                profile: fill(&segment.context.profile, &context.profile),
            },
        }
    } else {
        Decision::CloseAndStart { closed_at: t, t_end: t + INITIAL_SPAN_MS }
    }
}

/// Encodes a context for the chunk log, so the database can be rebuilt.
pub fn encode_context(context: &FrameContext) -> Vec<u8> {
    let mut out = Vec::new();
    for field in [&context.bundle_id, &context.window, &context.url, &context.profile] {
        match field {
            None => out.extend_from_slice(&u32::MAX.to_le_bytes()),
            Some(value) => {
                out.extend_from_slice(&(value.len() as u32).to_le_bytes());
                out.extend_from_slice(value.as_bytes());
            }
        }
    }
    out
}

/// Decodes a context from the chunk log. Returns `None` if it's malformed.
pub fn decode_context(mut bytes: &[u8]) -> Option<FrameContext> {
    let mut fields = [None, None, None, None];
    for field in &mut fields {
        let (length, rest) = bytes.split_first_chunk::<4>()?;
        let length = u32::from_le_bytes(*length);
        if length == u32::MAX {
            bytes = rest;
            continue;
        }
        let (value, rest) = rest.split_at_checked(length as usize)?;
        *field = Some(std::str::from_utf8(value).ok()?.to_owned());
        bytes = rest;
    }
    let [bundle_id, window, url, profile] = fields;
    Some(FrameContext { bundle_id, window, url, profile })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context(bundle: &str, window: Option<&str>, url: Option<&str>) -> FrameContext {
        FrameContext {
            bundle_id: Some(bundle.to_owned()),
            window: window.map(str::to_owned),
            url: url.map(str::to_owned),
            profile: None,
        }
    }

    fn open(t_start: i64, t_end: i64, ctx: FrameContext) -> OpenSegment {
        OpenSegment { t_start, t_end, context: ctx }
    }

    #[test]
    fn the_first_frame_starts_a_segment() {
        assert_eq!(
            decide(None, 1000, &FrameContext::default()),
            Decision::Start { t_end: 3000 }
        );
    }

    #[test]
    fn the_same_context_extends_the_segment() {
        let ctx = context("a", Some("w"), None);
        let segment = open(0, 2000, ctx.clone());
        assert_eq!(decide(Some(&segment), 4000, &ctx), Decision::Extend { t_end: 4000, context: ctx });
    }

    #[test]
    fn a_frame_inside_the_span_does_not_shrink_it() {
        let ctx = context("a", None, None);
        let segment = open(0, 10_000, ctx.clone());
        assert_eq!(
            decide(Some(&segment), 4000, &ctx),
            Decision::Extend { t_end: 10_000, context: ctx }
        );
    }

    #[test]
    fn a_long_gap_starts_a_segment_without_closing_the_old_one() {
        let ctx = context("a", None, None);
        let segment = open(0, 2000, ctx.clone());
        assert_eq!(
            decide(Some(&segment), 2000 + SEGMENT_GAP_MS, &ctx),
            Decision::Start { t_end: 2000 + SEGMENT_GAP_MS + INITIAL_SPAN_MS }
        );
        assert!(matches!(
            decide(Some(&segment), 2000 + SEGMENT_GAP_MS - 1, &ctx),
            Decision::Extend { .. }
        ));
    }

    #[test]
    fn a_different_app_closes_the_segment() {
        let segment = open(0, 2000, context("a", None, None));
        assert_eq!(
            decide(Some(&segment), 4000, &context("b", None, None)),
            Decision::CloseAndStart { closed_at: 4000, t_end: 6000 }
        );
    }

    #[test]
    fn a_different_window_or_url_closes_the_segment() {
        let segment = open(0, 2000, context("a", Some("w1"), Some("u1")));
        for other in [context("a", Some("w2"), Some("u1")), context("a", Some("w1"), Some("u2"))] {
            assert!(matches!(decide(Some(&segment), 4000, &other), Decision::CloseAndStart { .. }));
        }
    }

    #[test]
    fn a_missing_title_or_url_does_not_split_and_gets_filled_in() {
        let segment = open(0, 2000, context("a", None, Some("u")));
        let decision = decide(Some(&segment), 4000, &context("a", Some("w"), None));
        assert_eq!(
            decision,
            Decision::Extend { t_end: 4000, context: context("a", Some("w"), Some("u")) }
        );
    }

    #[test]
    fn a_missing_bundle_id_does_not_match_a_known_one() {
        // Unlike window and URL, the app must match exactly.
        let segment = open(0, 2000, context("a", None, None));
        let unknown = FrameContext::default();
        assert!(matches!(decide(Some(&segment), 4000, &unknown), Decision::CloseAndStart { .. }));
    }

    #[test]
    fn a_clock_jump_backward_starts_a_new_segment() {
        let ctx = context("a", None, None);
        let segment = open(10_000, 12_000, ctx.clone());
        assert_eq!(decide(Some(&segment), 5000, &ctx), Decision::Start { t_end: 7000 });
    }

    #[test]
    fn context_round_trips_including_absent_and_empty_fields() {
        let context = FrameContext {
            bundle_id: Some("com.example.app".to_owned()),
            window: None,
            url: Some(String::new()),
            profile: Some("Wörk 東京".to_owned()),
        };
        assert_eq!(decode_context(&encode_context(&context)), Some(context));
    }

    #[test]
    fn malformed_context_is_rejected_rather_than_panicking() {
        assert_eq!(decode_context(b""), None);
        assert_eq!(decode_context(&[1, 0, 0, 0]), None);
        assert_eq!(decode_context(&[9, 0, 0, 0, b'x']), None);
    }
}
