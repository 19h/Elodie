# How Elodie works

## The path a frame takes

1. **Capture.** Every 2 seconds, Elodie reads the window list, leaves out what must be hidden, and
   takes one picture of exactly the remaining windows on the display under the pointer. It's
   converted to 4:2:0 in display P3. An unchanged screen still costs a picture.
2. **Change check.** A Metal shader compares the frame with the last *stored* frame at half
   resolution. Too little change means it's dropped. Comparing with what's stored means slow
   changes add up until they count.
3. **Exclusion check.** It reads the window list again now the picture exists, and drops the frame
   if a window in it has turned out to need hiding, as when a title changes. A window that opened
   after the list was read can't be in the picture, so it costs nothing.
4. **Encoding.** Hardware HEVC at constant quality 0.75, with a keyframe at least every 30 frames
   and whenever the front app changes.
5. **The log.** Rust encrypts the sample and appends it to a chunk file. This is the source of
   truth. A database row follows within a second or so, and frame records can be rebuilt from the log.
   Stars, recognised text, and transcripts live only in the database.
6. **OCR.** A background task reads frames back from the log and reads their text. It holds no
   pixels in memory while it's behind, and it picks up where it left off after a crash.
7. **Text runs.** Consecutive frames with nearly the same text share one search document. Each
   frame records only which lines it shows and where.

## Why separate pictures, and not a stream

For as long as a ScreenCaptureKit stream of the display runs, macOS shows its screen sharing
indicator, and on this Mac streaming video went dark on the screen itself. That made Elodie impossible
to leave running while watching anything. So screen capture uses `CGWindowListCreateImageFromArray`
for one picture at a time, and protected video is left to come out black in the recording.

It costs three things:

- The call is marked obsolete in the SDK and could go in any macOS release. It's looked up when
  needed, so without it Elodie still opens with its history and says it can't record.
- A stream goes quiet when nothing changes. Pictures don't, so an unchanged screen costs a picture
  and a comparison every 2 seconds.
- Each picture gets converted with Core Image, where a stream delivered the format directly.

There's one thing it makes simpler. A picture holds only the windows named in its request, so the
filter updates, settle time, and constant watching of the window list that a stream needs are gone,
and so is the gap they left for very brief private windows.

System audio still comes from a stream, in `AudioRecorder`, while transcribing.

## Why it's split this way

Swift owns every Apple framework. Rust owns data and computation, and it never calls Swift.
Feature code sees only the `ElodieCore` protocol, so previews and tests run on a fake.

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

Opening also reads when that display has anything recorded, its screen and anything said, to find the
stretches with nothing in them. The strip and scrolling run on an axis where each gap of 30 seconds or
more is squeezed to a 36-point break. A break keeps its width at every zoom, so the axis is rebuilt when
the zoom changes. A segment's start and end are both in an index, so this read never touches the rows,
which hold window titles and web addresses.

With Accessibility on, an event tap takes the ⌘⇧ swipe away from the app underneath, on its own
thread so a busy main thread can't make other apps stutter. It sees scroll events only, and it passes
along everything except that gesture. Without Accessibility, a plain monitor opens the timeline, but
the app underneath also sees the scroll. That's always the case in the App Store edition.

## Editions

The direct download and the App Store edition come from the same code. The App Store requires the App
Sandbox, where reading another app through Accessibility fails even with permission, so the
`AppStore` configuration sets `ELODIE_APP_STORE`, and has no Accessibility code or event tap at all.
Everything that differs is in `App/Edition.swift`, plus `App/AccessibilityProbe.swift` and
`App/ScrollToOpen.swift`. The package never uses Accessibility itself: recording and onboarding are
handed a way to read a window, or a way to ask for permission, and do without if there isn't one.
Test support compiles to nothing outside debug builds. `scripts/check-bundle.sh` checks all of this
in the finished app.

## Keys

A random 256-bit master key lives in the login keychain. Each chunk has its own key derived from
it, and so does the database. A key is only created for a vault that doesn't exist yet. If a vault
exists and its key can't be read, that's an error to show, and a new key is only made if someone
chooses to start over, because otherwise it would orphan all recorded history.

Elodie can't open a vault made under the app's old name, because the labels that derive its keys, the
chunk file header, and the search tokenizer's name all changed with the name. That vault's files aren't
touched.

Each edition keeps its key under its own keychain name, so one never asks for the other's on a Mac with
both. Keychain lookups care about case, where the folder and settings don't, so a copy from when the bundle
ID had a capital E finds its key under the old name and moves it across. The old key only goes once the
new one is stored.

A recovery key restores a lost key. It only goes back in the keychain once it has been shown to open
the vault, so a wrong key can't do any harm.
