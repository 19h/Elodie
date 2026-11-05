# Spike results

What was measured, on what, and what it changed. Targets are from the plan; they
were proposals until measured here. Machine: M4 Max, macOS 27.2, unless noted.

## Spike 0: build chain and storage primitives (passed)

| Question | Result |
|---|---|
| SQLCipher crypto provider | `commoncrypto`, so no OpenSSL dependency |
| Versions | SQLCipher 4.19.0, SQLite 3.53.4 |
| FTS5 with `contentless_delete=1` | Works, including delete and `INSERT OR REPLACE` |
| Rust tokenizer via `fts5_api` | Registers per connection; works on read-only connections |
| `bm25(1.0, 0.3, 3.0)` on contentless | Ranks title, then text, then other |
| Encryption at rest | File has no SQLite header and no plaintext; wrong key is rejected |
| UniFFI 0.32 under Swift 6 strict concurrency | Sync, async, and error paths all cross correctly |
| Signed app calling Rust | Works, signed with Apple Development and hardened runtime |

The checks live on as `core/crates/store/tests/spike0_storage.rs` and
`Packages/RemindKit/Tests/CoreLiveTests`.

**Tokenizer change found while building.** Stemming breaks prefix search, because
`runn*` can't match a stored `run`. Documents now index the folded word and its
stem at the same position. Whole-word queries match the stem and prefix queries
match the folded word.

**Keychain finding: differs from the plan.** The data protection keychain returns
`-34018` (missing entitlement) without a provisioning profile, and a profile needs
an App ID registered on the developer account. The bundle ID isn't final, so this
waits for the release milestone.

The login keychain works today with no profile: add, read, and delete all succeed.
It doesn't sync, and its access list is tied to the code signature. It differs from
the plan's "after first unlock" in one way: if someone configures their login
keychain to lock on sleep, the key is unavailable until it's unlocked. Remind must
treat that as "temporarily unavailable" and never as "missing".

## Spike 6: durability (passed)

Run with `make torture`. It first proves its checker can fail: it damages a vault
in 8 ways and requires each to be detected.

| Test | Iterations | Frames verified | Undecodable | Violations | Worst recovery |
|---|---|---|---|---|---|
| SIGKILL at random moments | 1,000 | 34,189 | 0 | 0 | 231 ms |
| Simulated power cut | 300 | 131,525 | 0 | 0 | 265 ms |
| Disk genuinely full (64 MB APFS image) | 100 | 2,626 | 0 | 0 | 53 ms |

The target was at most 2 seconds of recovery. A quarter of kills skip recovery, so
the next process recovers and is often killed partway through.

**Limits of this evidence.** Power cuts are simulated, because nothing here can
remove power. The harness damages files the way a lost write cache could: truncated
or corrupted chunk tails, and a truncated or missing write-ahead log. It hasn't been
run on a machine that actually lost power.

**In-flight frames.** At 2 ms per frame the queue fills, so a kill can lose up to its
9 slots, which is the bound and not the expected loss. See below for a realistic pace.

**A real bug this found.** The first full-disk run failed with 63 violations: chunks
starting with a P-frame, which could never be decoded. When a write failed, frames
already queued would open a new chunk. `seal_all` had the same flaw. The appender now
refuses to open a chunk on anything but a keyframe.

**Tooling bug worth noting.** The first run of the suite silently did nothing: `status`
is read-only in zsh, so the script died after the self-test, and a `| tail` hid the exit
code. The results above come from a run with the real exit code recorded.

At one frame per 100 ms, still 20 times faster than real capture, at most 1 frame was
in flight at a kill. That meets the target of losing at most 2 ticks.

## Spike 3: storage, seeking, and picture quality (passed, on a synthetic screen)

3024×1964, worst case: every one of the 14,400 ticks in 8 hours is stored. Measured on
`SyntheticScreen`, so real usage will differ. A week of real recording is the true test.

| Rate | Keyframe every | GB per 8 hours | Seek p95 | Mean PSNR | Worst frame |
|---|---|---|---|---|---|
| Rewind's 0.06375 bits per pixel | 30 | 0.68 | 61 ms | 49.9 dB | **31.0 dB** |
| Rewind's 0.06375 bits per pixel | 150 | 0.67 | 252 ms | 54.3 dB | not measured |
| Quality 0.65 | 30 | 0.60 | 52 ms | 45.8 dB | 42.9 dB |
| **Quality 0.75, chosen** | **30** | **0.78** | under 100 ms | **49.8 dB** | **47.4 dB** |
| Quality 0.8 | 30 | 0.87 | 56 ms | 52.7 dB | 50.2 dB |

**Why constant quality.** At the same mean quality, average bitrate lets some frames fall
to 31 dB, which is visibly soft text. A scrubbing app is judged by the frame you land on.
Constant quality 0.75 holds 47.4 dB for 13% more storage, and it still fits the budget of
1 GB a day in the worst case.

**Rewind's figure holds up.** The spec calculated 47,328 bytes per frame and never measured
it. Rewind's setting produced 47.3 KB here.

**Keyframe interval.** At 150, seek p95 is 252 ms, against a target of 100 ms. 30 is right.

**The encoder holds nothing back.** The review recommended `MaxFrameDelayCount = 0`, but the
hardware HEVC encoder rejects it (`-12900`). Measured directly, it holds 0 frames, so a
crash can't lose frames inside it and no flushing is needed. Encoding takes about 16 ms.

## Spike 4: OCR from stored video (passed, on a synthetic screen)

2,000 frames at 3024×1964, while other heavy work was running.

| Measure | Result | Target |
|---|---|---|
| Of words the live frame read, stored video also read | **99.85%** | at least 98.5% |
| Of all words drawn, read from live | 96.15% | |
| Of all words drawn, read from stored video | 96.15% | |
| OCR per stored frame | p50 200 ms, p95 432 ms | p95 at most 1 s |
| Sustained at one frame per 2 s | about 10% of one core | at most 30% |
| 4:2:0 versus full colour, including coloured text | 96.96% vs 97.13% | |

So OCR always reads from the log, with no pixels held in memory. Capturing in 4:2:0 costs
almost nothing in accuracy and saves about 37 MB per 5K frame.

## Spike 5: text runs and database scale

See below for the large run. At 50,000 frames:

| Policy | Bytes per frame | With 1% OCR jitter |
|---|---|---|
| One document per frame | 12,429 | |
| Exact-match runs | 9,444 | 11,810 |
| **Union runs, chosen** | **3,582** | **3,871** |

Union runs are 2.6 times smaller than exact ones (target: at least 2), and 3 times smaller
with jitter, because one misread character closes an exact run.

Recall against one document per frame was 100% on 3,000 single words and 3,000 word pairs
(target: at least 99.5%). The index matched pairs in runs where no frame showed both 5% of
the time, so the per-frame re-check in search is needed.

## Things found by tests while building the interface and deletion

These are recorded because each would have been a visible failure.

- **A late settle could jump the picture back.** A settle scheduled just as a new request
  arrived could fire afterward and show the old frame. A generation counter now rules it out.
- **A Swift pattern bug.** In `case left, right where !isSearchFocused`, `where` only applies
  to `right`. The left arrow would have stepped through time while editing a search.
- **Search pages could be 90 results long.** Fetching extra rows for re-checking leaked into
  page sizes, so a buffer now keeps pages at 30.

**A deviation from the plan.** The plan said a partly deleted chunk would have its orphaned
frames re-encoded. Re-encoding needs Swift's encoder, and deletion runs in Rust, so those
frames are dropped instead: at most one group of pictures after the deleted range, or about
a minute at most.

## Spike 5 at scale: passes after a change

800,000 frames, 1% OCR jitter, 4.1 GB. That's about 56 days of the worst case (every tick
stored for 8 hours), or more like 4 months of real use. **The plan said to scale to 3 years,
which would break the 5 GB limit on test vaults, so this is not a 3-year test.** The slowest
query is bounded by the ranking window, not the size of the vault, which is why it should
hold up, but that's reasoning and hasn't been measured.

The index costs 5,140 bytes per frame at this scale, up from 3,582 at 50,000 frames.

| Query, first page | Ranked 100,000 | **Ranked 5,000, chosen** | Target |
|---|---|---|---|
| Common word, relevance p95 | 353 ms (**fails**) | **75 ms** | at most 300 ms |
| 3-letter prefix, relevance p95 | 412 ms (**fails**) | **84 ms** | at most 300 ms |
| Rare word, relevance p95 | 48 ms | 21 ms | |
| Common word, newest p95 | 17 ms | 17 ms | |
| Peak memory | 34 MB | | at most 150 MB |
| Deleting one day | 1.9 s | | at most 30 s |

Words rarer than 5,000 matches are still ranked across all of history. For more common words,
recency stands in for relevance. Paging continues past the window, so every match stays reachable.

The first large run reported "0 common terms" and exited 0, because a bug in the measuring tool
skipped the slowest query entirely. It now refuses to report in that case.

## Running the real app, with no permission needed

Screen Recording still hasn't been granted to the test build. But `SCShareableContent.currentProcess`
lets an app capture its own windows without it, including real glass, Metal, and IOSurface content.
That let everything below run. It's the closest thing yet to real use, and it found bugs that
356 passing tests hadn't.

**One thing to watch.** The current-process list isn't only this process's windows. Taking the largest
window from it returned the desktop wallpaper. `saveScreenshot` now checks ownership against the window
server's list and refuses anything else, so harness captures stay limited to harness windows.

### Bugs this found

| What | Why it mattered |
|---|---|
| OCR's 10-second timeout during first-run model compilation | Vision can't be cancelled, so timed-out calls piled up on its lock, about 30 at once, and each used up one of a frame's 3 attempts. New users would permanently lose text from their first frames. The timeout is gone, and compiling now happens on a small picture first |
| Exclusions in Settings didn't reach the recorder | An app excluded in Settings kept being recorded until the next launch |
| The text recognition setting did nothing, and OCR only read English | Now it uses the Mac's languages, or detects any language if chosen |
| Blank transcription language picker | The Mac's locale, such as English in Germany, often isn't one speech supports |
| Primary buttons went dark-on-grey in inactive windows | That's what onboarding looks like while you're in System Settings granting a permission |
| Controls unreadable over white pages: 2.29:1 | See the contrast table below |
| A black refresh, and stale controls, on opening | The panel came up before its frame was set, and kept its state from last time |
| The first scroll of the gesture was dropped, and the rest went to the app underneath | See the swipe below |
| Unoptimised Rust in development builds | Reading a group took 240 ms instead of 8 ms, so scrubbing would have felt broken |
| Duplicate apps in the exclusion list; retention only applied at launch; Show in Dock needed a relaunch | Smaller, but real |

### End to end (passed)

`--spike endtoend` puts a random word in a harness window and takes it through ScreenCaptureKit, the
Metal comparison, HEVC, the encrypted log, OCR, and search. The word was found 0.4 s after OCR started,
and the highlight landed inside the window where the word was. Of 14 frames received, 13 were dropped
as unchanged and 1 was stored.

### Spike 1: change detection (passed, on a harness window)

1,000 of 1,000 scripted changes seen, 0 missed, at 3456×2234. The stream delivered 228 frames in 5 idle
seconds at a 20 ms interval, so frame status alone doesn't keep it quiet in this mode. That supports
comparing against the last stored frame. **Energy isn't measured.** That needs `sudo powermetrics`,
and a stream of a whole display.

### Spike 7: overlay behaviour (partly answered)

| Question | Result |
|---|---|
| Does `sharingType = .none` hide the panel from capture? | This process's own capture of the panel returns a flat, blank image, and its ordinary windows capture normally. **Encouraging, but not the answer.** Only another process's capture can settle this |
| Does scrolling reach the timeline through the SwiftUI layer and the strip? | Yes, with real events through the real panel |
| Does typing start a search, and does the field take over? | Yes |
| Drag across text, then ⌘C | Copies it |
| ⌘Q | Closes the overlay, and doesn't quit |
| Input methods, full-screen apps, Stage Manager | Not tested. These need a person |

The panel takes keyboard focus without activating the app, as designed. So `make interaction-test`
really does take the keyboard for a few seconds, and it asks first. A key typed during one run landed
in the test and failed it.

### The swipe

⌘⇧ and scrolling up is one motion: the swipe that opens the timeline keeps moving through it, and
the app underneath stays still. With real events through the real coordinator, the first scroll isn't
lost, the swipe carries on after the keys are let go and through momentum, and opening costs 24 ms on
the main thread. **The event tap itself hasn't run**, because that needs Accessibility, so the app
underneath staying still is unproven. Its routing rules are unit tested.

### Spike 8 and the scrub budgets (M4 Max, 3024×1964, keyframe every 30)

| Measure | p50 | p95 | p99 | Budget |
|---|---|---|---|---|
| Cached scrub | 0.1 ms | 0.1 ms | 0.1 ms | p95 25 ms |
| Backward miss, exact frame | 43 ms | 78 ms | 136 ms | p95 120 ms, p99 280 ms |
| Backward miss, first change | 43 ms | 78 ms | 136 ms | 50 ms: **missed at p95** |
| Fast flick, per update | 0.2 ms | 14 ms | 15 ms | Keeps up with 60 Hz |
| Reading a group of 1.5 MB | 10 ms | 12 ms | 12 ms | |
| Creating a decoder | 2 ms | 3 ms | 3 ms | |
| Decoding a frame | 2.2 ms | 2.2 ms | 2.2 ms | Plan assumed 8 ms |

The first-change miss is the fully cold case, with nothing nearby in the cache. In real scrubbing a
nearby frame shows first. Showing the group's keyframe sooner would meet the number, but going backward
it would jump past the target and return, which is worse to look at. So it stays as it is.

Colour tags reaching the surface, lossless surfaces, and haptics aren't measured yet.

### First run

A clean first OCR spent **31 s** compiling Vision's models, on this M4 Max, and later launches are quick.
A slower Mac will take longer. Frames wait safely in the log meanwhile, but new recordings can't be
found by their text until it finishes.

### Contrast over hard backdrops (gate: 4.5:1)

The time pill's text over a frame, as captured, with real glass.

| Backdrop | Glass alone | Glass with an adaptive black tint | Glass over a 60% black fill (shipped) |
|---|---|---|---|
| White | 2.29:1 | 1.95:1 | **8.18:1** |
| Saturated | 4.10:1 | 3.91:1 | **11.69:1** |
| Dense black-on-white marks | 4.46:1 | 3.69:1 | **12.03:1** |
| Black | 17.43:1 | 21.00:1 | **20.21:1** |

Tinting made it worse: Liquid Glass adapts a tint to what's behind it. `make scenarios` checks this now.

## Open items

- **One test crash, not reproduced.** The test helper exited abnormally once while the 25-test
  Ingest suite was running under heavy load. The error line got cut off, and every full run since
  has passed all suites. Keep watching for this.
- **Two flaky tests were the tests' fault.** One checked before settling had been scheduled, and a
  shared fixture stopped waiting for indexing after 5 seconds without saying so, while commits can
  be 5 seconds apart. The fixture now waits longer and fails loudly. Six later runs of that suite passed.
- **Still needs Screen Recording:** spike 2 (the exclusion race), a stream of a whole display, and a
  real week of storage.
- **Still needs Accessibility:** the event tap, and with it the app underneath staying still.
- **Hotkey to first pixel isn't measured.** It takes over the screen, so it isn't part of `make bench`.
