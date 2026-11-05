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
