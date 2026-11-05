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
