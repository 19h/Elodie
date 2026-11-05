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
