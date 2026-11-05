# How Remind works

## The path a frame takes

1. **Capture.** A low-rate ScreenCaptureKit stream delivers frames from the display under the
   pointer, every 2 seconds at most. An unchanged screen delivers nothing.
2. **Change check.** A Metal shader compares the frame with the last *stored* frame at half
   resolution. Too little change means it's dropped. Comparing with what's stored means slow
   changes add up until they count.
3. **Exclusion check.** It works out which windows must be hidden, and drops the frame unless
   the filter in effect already covered them when the frame was composed.
4. **Encoding.** Hardware HEVC at constant quality 0.75, with a keyframe at least every 30 frames.
5. **The log.** Rust encrypts the sample and appends it to a chunk file. This is the source of
   truth. A database row follows within a second or so, and the database can be rebuilt from the log.
6. **OCR.** A background task reads frames back from the log and reads their text. It holds no
   pixels in memory while it's behind, and it picks up where it left off after a crash.
7. **Text runs.** Consecutive frames with nearly the same text share one search document. Each
   frame records only which lines it shows and where.

## Why it's split this way

Swift owns every Apple framework. Rust owns data and computation, and it never calls Swift.
Feature code sees only the `RemindCore` protocol, so previews and tests run on a fake.

## Crash safety

Each record goes out in a single write, and it's authenticated, so a torn record is detected and
trimmed. On launch, recovery replays what the database missed and removes rows the log no longer
has. Chunks are never reopened, because that could reuse a nonce. See `core/crates/engine/src/recovery.rs`.

## Search

A search first finds candidate runs in the index, then checks each against its individual frames,
because a run's document combines several frames, and two words might never have been on screen
together. BM25 ranks the newest 5,000 matches. Older ones follow, newest first.

## Keys

A random 256-bit master key lives in the login keychain. Each chunk has its own key derived from
it, and so does the database. A key is only created for a vault that doesn't exist yet. If a vault
exists and its key can't be read, that's an error to show, and a new key is never made, because
that would orphan all recorded history.
