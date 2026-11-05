# How Remind works

## The path a frame takes

1. **Capture.** A low-rate ScreenCaptureKit stream delivers frames from the display under the
   pointer, every 2 seconds at most. An unchanged screen delivers nothing.
2. **Change check.** A Metal shader compares the frame with the last *stored* frame at half
   resolution. Too little change means it's dropped. Comparing with what's stored means slow
   changes add up until they count.
3. **Exclusion check.** It works out which windows must be hidden, and drops the frame unless
   the filter in effect already covered them when the frame was composed. It also looks at the
   window list every 0.2 seconds between frames, trusts a new filter only after 0.25 seconds, and
   remembers any uncovered window it saw, so a window that closes first still makes earlier frames unsafe.
4. **Encoding.** Hardware HEVC at constant quality 0.75, with a keyframe at least every 30 frames
   and whenever the front app changes.
5. **The log.** Rust encrypts the sample and appends it to a chunk file. This is the source of
   truth. A database row follows within a second or so, and frame records can be rebuilt from the log.
   Stars, recognised text, and transcripts live only in the database.
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

A vault is locked to one process, because recovery treats open chunks as crash leftovers, so two at
once would damage each other's recordings.

## Deleting

Whole chunks are removed, and a chunk that's only partly affected is rewritten with the frames that
remain. Text is handled the same way, so deleted words leave the index too. Each app starts on a
keyframe, so removing a run of one app needs nothing re-encoded and takes nothing from the next. A
cut partway through a group of pictures also removes the rest of that group, and the timeline says
so before you confirm. Frame IDs are never reused, because anything still holding an old ID would
otherwise show a deleted frame. Giving space back rewrites the whole database, so it only happens
after a big deletion.

## Search

A search first finds candidate runs in the index, then checks each against its individual frames,
because a run's document combines several frames, and two words might never have been on screen
together. BM25 ranks the newest 5,000 matches. Older ones follow, newest first.

Filters also work with no words at all. That lists what they pick out, most recent first, without
touching the index.

## Opening the timeline

Each display keeps a panel ready, so opening only has to show it. The picture goes in before the
window comes up, so the first thing to reach the screen is the frame, with no black refresh. The
controls and strip rise a moment later, and they're hidden again on closing, so nothing from last
time can flash up.

With Accessibility on, an event tap takes the ⌘⇧ swipe away from the app underneath, on its own
thread so a busy main thread can't make other apps stutter. It sees scroll events only, and it passes
along everything except that gesture. Without Accessibility, a plain monitor opens the timeline, but
the app underneath also sees the scroll.

## Keys

A random 256-bit master key lives in the login keychain. Each chunk has its own key derived from
it, and so does the database. A key is only created for a vault that doesn't exist yet. If a vault
exists and its key can't be read, that's an error to show, and a new key is only made if someone
chooses to start over, because otherwise it would orphan all recorded history.

A recovery key restores a lost key. It only goes back in the keychain once it has been shown to open
the vault, so a wrong key can't do any harm.
