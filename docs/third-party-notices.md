# Third-party software

Regenerate before each release. Rust: `cd core && cargo tree --prefix none --edges normal`, with
licence terms from each crate. Check each licence's notice requirements when shipping.

| Component | Used for | Licence |
|---|---|---|
| SQLCipher (with SQLite) | Encrypted database | BSD-style (SQLite is public domain) |
| rusqlite | SQLite from Rust | MIT |
| UniFFI | Rust to Swift bindings | MPL-2.0 |
| RustCrypto `chacha20poly1305` | Encryption of recordings | Apache-2.0 or MIT |
| BLAKE3 | Key derivation | CC0 or Apache-2.0 |
| zstd | Text compression | BSD or GPL-2.0, used under BSD |
| rayon, crossbeam | Parallel work | Apache-2.0 or MIT |
| rust-stemmers | Word stems for search | MIT and BSD-3-Clause |
| unicode-normalization | Text folding | Apache-2.0 or MIT |
| KeyboardShortcuts | Global shortcuts | MIT |
| Sparkle | Updates | MIT, with BSD-style components |

The licences above were written from memory and haven't been checked against each package's
own file. Verify them before relying on this table.
