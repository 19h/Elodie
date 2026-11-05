# Remind

Find anything you've seen on your Mac. Remind records your screen in the background, reads
the words on it, and lets you search for them or scroll back to any moment. Recordings are
encrypted and stay on your Mac.

## Build

You need Xcode 27, Rust, and XcodeGen.

```
make app          # Builds the app into build/DerivedData
make test         # Runs the Rust and Swift tests, plus the privacy checks
make torture      # Crash, power-cut, and full-disk tests. Takes a few minutes
make release      # Signed release and disk image. Uploads nothing
```

## Layout

| Path | What it is |
|---|---|
| `core/` | The Rust core: encrypted log, database, text, search, timeline |
| `Packages/RemindKit/` | The Swift modules: capture, encoding, OCR, scrubbing, and each screen |
| `App/` | The app, which connects those together |
| `Widgets/` | The Control Center button |
| `docs/` | How it's built, measurements, privacy, and the release checklist |

See [docs/architecture.md](docs/architecture.md) for how it fits together, and
[docs/spikes.md](docs/spikes.md) for what's been measured and what hasn't.
