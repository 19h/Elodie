<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Remind's icon: three frames in depth, crossed by a playhead">
</p>

<h1 align="center">Remind</h1>

<p align="center">
  <strong>Find anything you've seen on your Mac.</strong>
</p>

<p align="center">
  Remind records your screen in the background, reads the words on it, and lets you search for them or scroll back to any moment.<br>
  Recordings are encrypted and stay on your Mac.
</p>

<p align="center">
  macOS 26 or later · Apple Silicon · No account · No analytics · No cloud
</p>

![The timeline opened for search: a recorded frame fills the screen, with the search panel at the top and the strip of apps along the bottom](docs/images/timeline.png)

<p align="center"><sub>All screenshots show synthetic test data.</sub></p>

> [!IMPORTANT]
> **Remind is pre-release software, at version 0.1.0.** There's no download yet, so the only way to run it is to build it. The name and bundle ID aren't final, and some checks are still open, including whether the timeline stays hidden during screen sharing. See [Status](#status) and [Known limitations](#known-limitations).

## Contents

- [What it does](#what-it-does)
- [Status](#status)
- [Getting started](#getting-started)
- [Using Remind](#using-remind)
  - [The timeline](#the-timeline)
  - [Search](#search)
  - [Ask](#ask)
  - [Daily Recap](#daily-recap)
  - [Meetings and transcripts](#meetings-and-transcripts)
  - [Controlling what's recorded](#controlling-whats-recorded)
- [Keyboard and gestures](#keyboard-and-gestures)
- [Settings](#settings)
- [Shortcuts, links, and Control Center](#shortcuts-links-and-control-center)
- [Privacy and security](#privacy-and-security)
- [How it works](#how-it-works)
- [Measurements](#measurements)
- [Developing Remind](#developing-remind)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Documentation](#documentation)
- [Built with](#built-with)
- [Licence](#licence)

## What it does

You saw it somewhere: a figure in a spreadsheet, an error message, a flight time, a page you closed last Tuesday. Remind keeps a private, searchable history of your screen, so you can get it back by typing a word you remember or by scrolling back to the moment.

| | |
|---|---|
| **Timeline** | Scroll back through your screen in a full-screen overlay that opens without switching apps. |
| **Search** | The words on your screen are read and indexed on your Mac. A result takes you to the moment they were on screen, with the match outlined. |
| **Ask** | Ask a question in plain language. Apple's on-device model answers from your recordings and cites the moments it used. |
| **Daily Recap** | See where a day went: time per app, activity by the hour, your longest stretches, and your meetings. |
| **Meetings** | Optionally transcribe your microphone and your computer's audio, labelled You and Others, and search it alongside your screen. The audio itself isn't kept. |
| **Privacy** | Recordings are encrypted. You can exclude apps, private browser windows are left out, and the only network use is an update check you can turn off. |

Capture, encoding, text recognition, search, transcription, and answers all run on your Mac.

## Status

| | |
|---|---|
| **Version** | 0.1.0, unreleased |
| **Download** | None yet. Build from source. |
| **Name** | A working name. "Remind" is also used by a school-messaging app, and it needs a trademark check. |
| **Bundle ID** | `app.remind.Remind.dev` is a placeholder. |
| **Updates** | Sparkle is wired in, but builds have no updater until a feed and signing key are set. |
| **Tested on** | Benchmarks have only run on an M4 Max with synthetic screens. See [Measurements](#measurements). |
| **Licence** | [MIT](LICENSE) |

[docs/release-checklist.md](docs/release-checklist.md) lists everything left to do before a public release.

## Getting started

### Requirements

To run Remind:

- A Mac with Apple Silicon
- macOS 26 or later
- Apple Intelligence, only if you want written answers in Ask and meeting summaries. Everything else works without it.

To build it:

- Xcode 27
- Rust 1.99 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- An Apple Development signing identity

### Build and run

```sh
git clone git@github.com:19h/Remind.git
cd Remind
```

Set `DEVELOPMENT_TEAM` in `project.yml` to your own team ID. Debug builds use your Apple Development identity on purpose: macOS ties permission grants to the signature, so a real identity keeps them across rebuilds.

```sh
make app
open build/DerivedData/Build/Products/Debug/Remind.app
```

`make app` builds the Rust core, generates its Swift bindings, generates the Xcode project, and builds the app. To work in Xcode, run `make project` and open `Remind.xcodeproj`. The project and the core's framework are generated, so neither is checked in.

> [!WARNING]
> A development build is the real app. Once you finish setup, it records your actual screen into `~/Library/Application Support/app.remind.Remind.dev/vault`. To check a build without recording anything, run `make self-check`, which opens a temporary vault, prints the core's versions, and exits.

### First run

Setup explains what Remind is and how it works, then asks for permissions:

| Permission | | What it's for |
|---|---|---|
| Screen Recording | Required | Takes a picture of your screen every few seconds. |
| Accessibility | Required | Reads the front window's title and web address, spots private browser windows, and lets the ⌘⇧ scroll gesture take over from the app underneath. |
| Microphone | Optional | Transcribes meetings you choose to record. |
| Calendar | Optional | Names meetings. It's only requested when you turn this on in Settings → Meetings. |

macOS only applies a new Screen Recording grant to new processes, so Remind offers to reopen itself and comes back at the same step. macOS also asks you to confirm screen recording from time to time. If recording stops, the menu bar icon tells you.

After setup, Remind lives in the menu bar and starts recording. The first few times you open the timeline, three short hints show you how to scroll, search, and get back.

## Using Remind

### The timeline

Hold ⌘⇧ and scroll back from any app. The swipe that opens the timeline is the same one that moves through it, so it looks like the screen itself going back in time. Press Esc to return to what you were doing.

The overlay opens on the display under your pointer. It never activates Remind, so the app you were using stays active, opening causes no Space or stage switch, and Esc puts you back with focus where it was.

- **Scroll or swipe** to move through time. Scrolling moves the strip under a fixed playhead, and it follows your natural scrolling setting. Hold ⌥ to go 8 times faster.
- **Pinch** to zoom the strip, from a whole day on screen down to seconds.
- **The strip** shows which app was in front at each moment, in colour and with app icons.
- **The time pill** opens Jump to Date & Time. The calendar and hours dim wherever nothing was recorded, or you can type a phrase such as "yesterday 3pm" or "March 4". A phrase with no year or day means the most recent time it happened.
- **Open** goes back to the app you were in, or reopens the page in the same browser.
- **The arrow at the end of the strip** returns to now.

![Jump to Date & Time, with a calendar of the month, a list of hours, and a field for typing a phrase](docs/images/jump-to-date.png)

**Text on a frame is live.** The pointer becomes an I-beam over recognised text. Drag to select lines, then press ⌘C. With nothing selected, ⌘C copies all the text on the frame.

**A frame can be dragged out.** Drag anywhere that isn't text to drop the frame into Finder or another app as a PNG. That temporary copy is unencrypted, so it's deleted about a minute after the drop.

The **⋯** menu holds everything else:

| Action | What it does |
|---|---|
| Star this moment | Marks the frame, so the Starred search filter finds it. |
| Copy text on screen | Copies the selected lines, or the whole frame's text. |
| Copy image, Save image… | Copies the frame, or saves it as a PNG. |
| Copy link to this moment | Copies a [`remind://` link](#moment-links). |
| Export 5 minutes as video… | Saves the 5 minutes around the playhead as an MP4, without re-encoding. This is an unencrypted copy, and the save panel says so. |
| Exclude this app from recording | Leaves the app out of recording from now on, effective at once. |
| Forget the last 5 minutes… | Permanently deletes the 5 minutes before now, wherever the playhead is. It asks first. |

### Search

Press ⌘⇧Space from anywhere, or start typing while the timeline is open. Results appear as you type.

![Search results for the word "accompany": a card showing a crop of the frame with the match outlined, the window title, and how long ago it was](docs/images/search-expanded.png)

Each result is a crop of the frame centred on the match, with the window title and the time. Click one to go to that moment, with each match outlined and numbered. Hover over it for **Open in** the app it came from. Something that was said, rather than shown, appears as the words themselves.

| Type this | To find |
|---|---|
| `quarterly review` | Moments showing both words. Every word has to match. |
| `rev` | Words starting with this. The last word matches as a prefix while you're still typing it, so this finds `review` and `revenue`. |
| `running ` | Other forms of a finished word, such as `run` and `runs`. A space or another word after it marks it finished. Word forms are English. |
| `"quarterly budget"` | The words next to each other on one line. A phrase can't match across two lines. |
| `cafe` | `Café`. Case and accents don't matter, and `strasse` finds `Straße`. |
| `example.com` | `example` followed by `com`. Punctuation separates words. |
| Chinese, Japanese, Korean | Text with no spaces is indexed in overlapping pairs of characters. |

There are no operators: `OR`, `NOT`, and `*` are treated as text.

Three filters narrow a search:

- **Apps** limits it to the apps you pick.
- **Meetings** limits it to what was said.
- **Starred** limits it to frames you've starred.

**Ranking.** A match in the window title ranks above one in the front window, which ranks above one elsewhere on screen. The newest 5,000 matches are ranked by relevance, and older ones follow, newest first, so every match stays reachable. Words rarer than that are ranked across all of your history.

**Every result is a real moment.** To save space, the index merges frames that show nearly the same text, so two words might share a document without ever being on screen together. Each hit is checked against individual frames before you see it.

### Ask

Press ⌘⇧- (the key to the right of 0, which is `ß` on a German keyboard) and ask something like "Where did I see the budget numbers?"

1. **Planning.** Your question becomes search terms, with no model involved. Filler words are dropped in English and German, quoted phrases stay whole, and "yesterday", "today", "last week", "last month", or a date limits when to look.
2. **Finding.** It searches for all the words together, then each alone, and collects up to 16 moments.
3. **Answering.** As many excerpts as fit go to Apple's on-device model, which is told to answer only from them and to cite each fact.
4. **Citing.** Citations such as [2] link to the moment they came from. Only sources that exist become links, because a model can invent a number.

**It works without the model.** If this Mac isn't eligible, Apple Intelligence is off, the model is still downloading, or it declines to answer, you still get the matching moments and a note saying why.

**Text on your screen can't give it orders.** Anything can appear on a screen, including text written to look like instructions. The model has no tools, it's told that excerpts are data, and those excerpts can't break out of their place in the prompt. The worst a hostile page could do is mislead an answer, so check the citations when it matters.

Each question is answered on its own, with no memory of earlier ones. Ask never uses a cloud model, and a build check enforces that.

### Daily Recap

Open **Daily Recap** from the menu bar, or give it a shortcut in Settings. It's worked out from your local data, with no model involved, and shows one day at a time:

- Total time on screen, and activity by the hour
- Your top 8 apps, with time in each
- Your 10 longest stretches of at least 5 minutes. Click one to go to that moment.
- The meetings you transcribed

### Meetings and transcripts

Remind checks for a call every 5 seconds. It recognises Zoom, Slack huddles, Webex, and the Microsoft Teams app. What happens next is up to you, in Settings → Meetings:

- **Ask me**, the default, because recording other people is a decision to make each time
- **Record automatically**
- **Don't record**

About 30 seconds after a call's signs disappear, transcription stops by itself. You can also start or stop it at any time with the **Audio capture** switch in the menu bar.

Browser calls aren't detected yet, so use the switch for those. See [Known limitations](#known-limitations).

**How transcription works.** Apple's speech framework transcribes on your Mac, and macOS downloads each language the first time it's used. Audio is never written to disk. The microphone and your computer's audio are transcribed separately, which labels each line **You** or **Others**. When your microphone picks up the call from your speakers, a word is dropped only if the same word came from the speakers at around the same moment. What you say over someone else is kept, unless it's that same word.

**Afterwards.** What was said is searchable alongside your screen, and the Meetings filter narrows to it. **Last transcript** in the menu bar opens the most recent one. Click a line to go to that moment on the timeline, or use the Details tab to summarise the meeting on your Mac. A long meeting is cut to what fits the model.

**Calendar names** are off by default. When you turn them on, Remind reads the event in progress, or one starting within 5 minutes, and keeps only its title with the transcript.

> [!NOTE]
> Laws on recording conversations differ by place, and many require everyone's consent. Getting consent is up to you.

### Controlling what's recorded

<img src="docs/images/status-menu.png" width="320" align="right" alt="Remind's menu: Search, Ask, Daily Recap, switches for screen and audio capture, Star moment, Pause for, Forget the last 5 minutes, Settings, and Quit">

The menu bar icon shows the state at a glance. A filled frame means recording, an outline means paused, and a line through it means there's a problem, which the menu explains.

- **Pause** with the Screen capture switch, for 15 minutes or an hour, or from Shortcuts or Control Center. If you pause with no end time, a card reminds you every hour. You can turn that off in Settings.
- **Exclude an app** in Settings → Screen, or from the timeline's ⋯ menu. It takes effect at once.
- **Forget the last 5 minutes** from the menu bar or the timeline. It's permanent, so it asks first.
- **Set how long to keep recordings** in Settings → Storage.

Remind also adjusts by itself:

- It stops recording when your Mac sleeps or locks, and starts again afterwards.
- It records the display your pointer is on, and moves once the pointer has stayed on another display for 2 seconds.
- In Low Power Mode, it captures every 4 seconds instead of every 2.
- When your Mac runs hot, text recognition pauses. Capture carries on, and frames wait safely in the log.

<br clear="right">

## Keyboard and gestures

**From anywhere**

| Input | Action |
|---|---|
| ⌘⇧ and scroll back | Open the timeline. |
| ⌘⇧Space | Open search. |
| ⌘⇧- | Open Ask. This is the key to the right of 0, or `ß` on a German keyboard. |
| Open Remind again while it's running | Open search. |

You can change the two key combinations in Settings → Shortcuts. You can also assign shortcuts there for Daily Recap, Star moment, and Audio capture, which have none by default.

**In the timeline**

| Input | Action |
|---|---|
| Scroll or swipe | Move through time. |
| ⌥ and scroll | Move 8 times faster. |
| Pinch | Zoom the strip. |
| ← → | Go to the previous or next frame. |
| ⌥← ⌥→ | Go to the previous or next stretch in an app. Going back first returns to the start of the current one. |
| End | Go back to now. |
| Start typing, or ⌘F | Search. |
| Return | Open the app or page from this moment. |
| ⌘C | Copy the selected text, or all the text on the frame. |
| ⌘⇧S | Star this moment. |
| Esc | Back out one level: date panel, search text, results, search panel, then the timeline itself. |
| ⌘Q, ⌘W | The same as Esc, so they can't quit the recorder while the overlay is up. |

While the search field has focus, the arrow keys, Return, and ⌘C go to the field instead.

The overlay also closes by itself when you switch Spaces or apps, when the screen sleeps or locks, and when displays change.

## Settings

| Tab | Setting | Default | Notes |
|---|---|---|---|
| General | Open Remind at login | Chosen during setup | It comes back after a crash, but not after you quit. |
| | Remind me when recording is paused | On | Hourly, for pauses with no end time. |
| | Show in Dock | Off | |
| | Check for updates automatically | On | Only applies to builds with an updater. |
| Screen | Exclude apps | None | Choose from installed or running apps, or add one with **+**. |
| | Don't record private or incognito browser windows | On | Warns here if it can't check right now. |
| | Text recognition | Standard | Standard reads the languages your Mac uses. Additional languages detects any language, and uses more system resources. |
| Audio | Transcription language | Your Mac's language | Uses the closest supported language. |
| | Record | Microphone and speaker audio | Or microphone only, or speaker audio only. |
| Meetings | When a meeting is detected | Ask me | Or record automatically, or don't record. |
| | Name meetings from your calendar | Off | Requests calendar access when you turn it on. |
| Storage | Keep recordings for | Forever | 1 week, 1 month, 3 months, 6 months, 1 year, or forever. Whole days are removed. Shortening it asks before deleting anything. |
| | Space used | | Shows the total, an estimate per day from your own recordings, and free disk space. |
| | Recovery key | | Saves a file that can decrypt your recordings. Remind reminds you once, a week after first run. See [Known limitations](#known-limitations). |
| | Location | | Shows the vault in Finder. |
| | Delete all recordings… | | Deletes your screen recordings and transcripts. It can't be undone. |
| Shortcuts | Search, Ask, Daily Recap, Star moment, Audio capture | | |

## Shortcuts, links, and Control Center

### Shortcuts and Siri

| Action | Input | Siri phrase |
|---|---|---|
| Search Remind | | "Search Remind" |
| Go to a moment in Remind | Date and time | |
| Pause Remind recording | Minutes, optional. Leave it empty to pause until you resume. | "Pause Remind" |
| Resume Remind recording | | "Resume Remind" |

### Moment links

`remind://moment/<milliseconds since 1970>` opens the timeline at that moment:

```sh
open "remind://moment/1800000000000"
```

**Copy link to this moment** in the ⋯ menu makes one for you. These links come from outside the app, so anything malformed is ignored, and a link can only say where to look.

### Control Center

Add the **Remind recording** control to Control Center or the menu bar to pause and resume. It runs in a separate sandboxed process and signals the app with a notification that carries no data.

## Privacy and security

**Remind keeps everything on your Mac.** It has no account, no analytics, and no crash reporting. It doesn't upload your recordings, text, or transcripts anywhere. [docs/PRIVACY.md](docs/PRIVACY.md) is the full statement. This is a summary.

| | |
|---|---|
| **Recorded** | A picture of the display your pointer is on, about every 2 seconds when it has changed. The text on it. The app, window title, and web address of what's in front. A transcript, if you turn that on. |
| **Left out** | Apps you exclude. Private and incognito browser windows. Remind's own windows. The audio behind a transcript. |
| **Not protected** | **Password fields and other sensitive content in ordinary windows do get recorded if they're visible.** Exclude any app you don't want recorded. |

### Encryption

| What | How |
|---|---|
| Recordings | ChaCha20-Poly1305. Each chunk file has its own key, derived with BLAKE3. |
| Database, including all text and transcripts | SQLCipher, with a key derived with BLAKE3. |
| Master key | Random, 256-bit, in your login keychain. A key is only created for a vault that doesn't exist yet. |
| Backups | The vault is excluded from Time Machine, because a backup couldn't be read without the key anyway. |

Chunk files are stored by random ID rather than by date, so the folder layout doesn't reveal when you were active.

### Private windows

Browsers offer no API for this, so Remind recognises private windows from their titles, in 16 languages. Arc also marks them in a way that doesn't depend on language. A browser is recognised by how it's built rather than from a fixed list, so new and renamed Chromium browsers are covered.

**When in doubt, a frame is dropped.** A frame is kept only if the capture filter in effect when it was composed already hid every window that must be hidden. While a new private window is on its way into the filter, frames are thrown away. If a browser doesn't answer within 50 ms, that frame is dropped too, and Settings tells you if it keeps happening.

### What it can't protect you from

- **Your own account.** Anyone who can use your Mac while you're logged in can open Remind and see your history.
- **Copies you make.** Exported videos, saved images, and dragged frames aren't encrypted. A saved recovery key can decrypt everything, so keep it somewhere safe.
- **Deleted blocks.** Deleting removes recordings and their text from Remind's files, and a few frames just after a deleted period also go, because they can't be decoded without what came before. Like any file deletion, old encrypted blocks can stay on the drive or in APFS snapshots until they're overwritten.

### The network

Remind uses the network for one thing: Sparkle's update check, which you can turn off. It's limited to `App/Updater.swift`, and a build with no update feed and signing key doesn't run it at all. macOS downloads its own language models for transcription and Ask, and Remind sends nothing in that process.

These promises are checked against the code. `make check-privacy` runs as part of `make test` and before every release build, and it fails if:

- Anything outside Sparkle can use the network
- Sparkle is imported outside `App/Updater.swift`
- The cloud model is used
- An analytics or crash-reporting framework is imported
- The Rust core links network calls or depends on a networking crate

## How it works

Swift owns every Apple framework. Rust owns data and computation, and it never calls Swift. Feature code sees only the `RemindCore` protocol, so previews and tests can run on a fake.

```text
  App/                 menu bar, overlay coordination, keychain, updater, intents
   │
   ├── Feature*        Timeline, Search, Ask, Recap, Meetings, Onboarding, Settings
   ├── OverlayShell    the panel and its input            StripRenderer  the Metal strip
   ├── FrameEngine     scrubbing, decoding, MP4 export    DesignSystem   colours, chrome
   ├── Ingest          change check, encoder, OCR         Capture        streams, exclusions
   ├── Audio           transcription, meeting detection
   │
   └── CoreAPI         the RemindCore protocol
        ├── CoreFake   a stand-in for previews and tests
        └── CoreLive ──▶ CoreABI ──▶ RemindCoreFFI.xcframework
                                        │  UniFFI
  ──────────────────────────────────────┼───────────────────────────────────
  core/ (Rust)                          ▼
                                       ffi      the API Swift calls
                                        │
                                      engine    write path, recovery, deletion
                                        │
             ┌──────────────┬───────────┴──┬──────────────┐
           vault          store          search        timeline
       encrypted log   SQLCipher, FTS5      │         strip, recaps
                            │               │
                            └──── text ─────┘
                              tokenizer, runs
```

### The path a frame takes

1. **Capture.** A low-rate ScreenCaptureKit stream delivers frames at most every 2 seconds. An unchanged screen delivers nothing, and the cursor isn't captured.
2. **Change check.** A Metal shader compares the frame with the last *stored* frame at half resolution. It takes about 1,000 changed pixels to keep a frame. Comparing with what's stored, rather than the previous capture, means slow changes add up until they count. Black frames are skipped.
3. **Exclusion check.** It works out which windows must be hidden, and drops the frame unless the filter in effect already covered them.
4. **Encoding.** Hardware HEVC at constant quality 0.75, with a keyframe at least every 30 frames. The encoder holds nothing back, so a crash can't lose frames inside it.
5. **The log.** Rust encrypts the sample and appends it to a chunk file. This is the source of truth. A database row follows within a second or so, and the log never waits for it, so a stalled database can't delay a frame.
6. **OCR.** A background task reads frames back from the log with Apple's Vision framework. It holds no pixels in memory while it's behind, and it picks up where it left off after a crash. When it's more than a minute behind, frames that stayed on screen for at least 4 seconds go first, because that's what you were likely reading.
7. **Text runs.** Consecutive frames whose lines overlap the first frame's by at least 80% share one search document, for up to 5 minutes. Each frame records only which lines it shows and where.

### What's on disk

```text
~/Library/Application Support/<bundle ID>/vault/
├── vault.db                 encrypted database: frames, text, search index, transcripts
└── chunks/<ab>/<ab…>.chunk  encrypted video, named by random ID
```

A chunk holds one display's frames and is replaced at the next keyframe after 5 minutes or 64 MB. Every record is sealed with its sequence number as the nonce, so **a chunk is never reopened for writing**, because resuming after a crash could repeat a nonce. A new session always starts a new chunk. The format is documented in `core/crates/vault/src/lib.rs`.

The database is a projection of the log, and its frame records can be rebuilt by scanning the chunks. Stars, recognised text, and transcripts live only in the database.

### Search

The index is an FTS5 table with no stored content, using a custom Rust tokenizer. Each word is stored in its folded form and, if different, its English stem at the same position. Whole-word queries match the stem and prefix queries match the folded form, because `runn*` could never match a stored `run`.

A search first finds candidate runs in the index, then checks each against its individual frames to find a moment that really showed every term, and where. In testing, the index matched word pairs in runs where no single frame showed both 5% of the time, so this check matters.

### Scrubbing

Scrubbing outruns decoding, so the engine always works on the latest request and skips any in between. It decodes every frame when the playhead is slow, only keyframes when it's fast, and when it stops it decodes the exact frame and then the groups on either side, so the next step is instant. The picture never blanks: until the right frame is ready, the closest cached one stays up. The cache takes 10% of memory, between 700 MB and 1.4 GB, and is freed when the overlay closes.

### When things go wrong

| Situation | What Remind does |
|---|---|
| Crash or kill | Each record goes out in a single authenticated write, so a torn one is detected and trimmed. On launch, recovery replays what the database missed. |
| Power cut | The log is flushed with `F_FULLFSYNC` every 5 seconds, which bounds the loss. Recovery removes database rows the log no longer has. |
| Repeated crashes | launchd brings Remind back after a crash. After 3 crashes in 5 minutes, it comes back paused and says why. |
| Less than 10 GB free | Reading of frames set aside for later pauses. |
| Less than 2 GB free | Recording stops and says so. It resumes by itself above 4 GB. |
| Encoder keeps failing | After 3 failures in a minute, capture stops and says so. Raw frames are never stored instead. |
| A frame crashes OCR | An attempt is recorded before OCR runs, so a frame is given up on after 3 tries rather than crashing every launch. |
| Keychain locked | Treated as temporarily unavailable, and never as missing. |
| Key missing | Shown as an error. A new key is never created, because that would orphan all recorded history. |

### Design

Remind uses system Liquid Glass with its own accent, verdigris, the patina time leaves on copper (`#45C9B1` in dark mode, `#0B7F70` in light). It's distinct from system blue and from the red and orange macOS uses for recording indicators. Search matches are marked in `#FFC83D`. Animations respect Reduce Motion.

## Measurements

These come from [docs/spikes.md](docs/spikes.md), which has the full results and what each one changed.

> [!CAUTION]
> Everything here ran on an M4 Max with macOS 27.2, which flatters the numbers, and storage figures come from a synthetic screen. Remind hasn't been measured on a base MacBook Air, over a real week of use, or for energy. Treat these as evidence about the design, not as promises about your Mac.

**Storage and seeking.** At 3024×1964, in the worst case, with all 14,400 ticks in 8 hours stored:

| Measure | Result | Target |
|---|---|---|
| Storage per 8 hours | 0.78 GB | At most 1 GB a day |
| Seek, p95 | Under 100 ms | 100 ms |
| Picture quality, mean | 49.8 dB | |
| Picture quality, worst frame | 47.4 dB | |

**Text recognition.** 2,000 frames at 3024×1964, while other heavy work was running:

| Measure | Result | Target |
|---|---|---|
| Words from the live frame also read from stored video | 99.85% | At least 98.5% |
| Time per frame | p50 200 ms, p95 432 ms | p95 at most 1 s |
| Sustained at one frame per 2 seconds | About 10% of one core | At most 30% |

**Search.** 800,000 frames in 4.1 GB, which is about 56 days of the worst case or more like 4 months of real use. This isn't a 3-year test, because that would break the 5 GB limit on test vaults. The slowest query is bounded by the ranking window rather than the size of the vault, so it should hold up, but that's reasoning and hasn't been measured.

| Measure | Result | Target |
|---|---|---|
| Common word, first page, p95 | 75 ms | At most 300 ms |
| 3-letter prefix, first page, p95 | 84 ms | At most 300 ms |
| Rare word, first page, p95 | 21 ms | |
| Deleting one day | 1.9 s | At most 30 s |
| Index size | 5,140 bytes per frame | |
| Recall on 3,000 words and 3,000 pairs, at 50,000 frames | 100% | At least 99.5% |

**Durability.** From `make torture`, which first proves its checker can fail by damaging a vault in 8 ways and requiring each to be detected:

| Test | Iterations | Frames verified | Violations | Worst recovery |
|---|---|---|---|---|
| SIGKILL at random moments | 1,000 | 34,189 | 0 | 231 ms |
| Simulated power cut | 300 | 131,525 | 0 | 265 ms |
| Disk genuinely full (64 MB APFS image) | 100 | 2,626 | 0 | 53 ms |

Power cuts are simulated by damaging files the way a lost write cache could. This hasn't been run on a machine that actually lost power.

## Developing Remind

### Make targets

| Command | What it does |
|---|---|
| `make app` | Builds the debug app into `build/DerivedData`. |
| `make core` | Builds the Rust core, its bindings, and its framework. |
| `make project` | Builds the core and generates `Remind.xcodeproj`. |
| `make test` | Runs the Rust tests, the Swift tests, and the privacy checks. |
| `make test-rust`, `make test-swift` | Runs one side of that. |
| `make self-check` | Builds the app and proves a signed build can reach the Rust core. |
| `make torture` | Runs the crash, power-cut, and full-disk tests. Takes a few minutes. `TORTURE_DIR` sets where they run. |
| `make check-privacy` | Checks the privacy promises against the code. |
| `make release` | Builds a signed release and disk image. Uploads nothing. |
| `make clean` | Removes build products and everything generated. |

### Tests

There are more than 300 Rust and Swift tests:

- **Rust** has unit tests, property tests for the chunk format, tokenizer, and text codec, and integration tests for durability, search end to end, and storage.
- **Swift** has a suite per area: Ask, Audio, Capture, CoreLive, FrameEngine, Ingest, and the interface. Interface tests run against `CoreFake`, while the Ingest, FrameEngine, and Audio suites also use the real core through `CoreLive`.

### Measuring and checking by hand

```sh
# Encoder, storage, and OCR measurements. These need no permissions.
swift run --package-path Packages/RemindKit remind-spike holdback
swift run --package-path Packages/RemindKit remind-spike storage 450
swift run --package-path Packages/RemindKit remind-spike worst-case 450
swift run --package-path Packages/RemindKit remind-spike ocr 2000

# Large synthetic databases, for scale. 800,000 frames take about 4 GB.
cd core
cargo run --release -p fixturegen -- build <dir> <frames> union|exact|per-frame [jitter%]
cargo run --release -p fixturegen -- query <dir>
cargo run --release -p fixturegen -- recall <union-dir> <per-frame-dir>
```

Debug builds of the app have two more modes. Launch them through `open`, so macOS treats Remind as the app asking for permission:

```sh
APP=build/DerivedData/Build/Products/Debug/Remind.app

# Shows one screen with fixture data, screenshots its own window, and exits.
open -n $APP --args --scenario search-expanded --out /path/to/shot.png

# Capture checks. Frames are examined in memory and thrown away.
open -n $APP --args --spike capture --out /path/to/report.txt
```

- **Scenarios:** `timeline`, `search-compact`, `search-expanded`, `jump-to-date`, `coach-marks`, `status-menu`, `overlay-input`, `onboarding-welcome`, `onboarding-how`, `onboarding-permissions`, and `settings-general`, `-screen`, `-audio`, `-meetings`, `-storage`, `-shortcuts`.
- **Spikes:** `capture`, `privacy`, `energy`, `browsers`.

`settings-screen` lists the apps installed on your Mac, so check it before sharing the picture.

### Working rules

These protect people's data, and several are enforced by a test or a check:

- **Keep real data out of tests.** Test vaults go in a scratch directory, stay under 5 GB, and are deleted afterwards. Live capture tests look only at windows the harness draws. Recorded data and keys never go in the repository.
- **Never create a new key for an existing vault.** It would orphan all recorded history, so a missing key is an error to show.
- **Never change how keys are derived.** Known-answer tests guard this, because existing vaults depend on those values.
- **Never edit a released migration.** Add a new one.
- **Never reopen a chunk for writing.** It could repeat a nonce.
- **A chunk must start with a keyframe.** A full-disk test caught chunks that could never be decoded because of this.
- **Keep the split.** Swift owns Apple frameworks, Rust owns data and computation, and Rust never calls Swift. New core features go through `ffi`, the `RemindCore` protocol, `CoreLive`, and `CoreFake`.
- **New network use needs a very good reason.** `make check-privacy` will fail, and the privacy statement would have to change.

The Swift code builds under Swift 6 with complete strict concurrency.

### Releasing

```sh
make release                                 # Signed build and disk image in build/release
scripts/release.sh --notarize <profile>      # The same, then sends it to Apple to notarize
```

Release builds need a Developer ID Application identity. Notarizing needs a profile stored with `xcrun notarytool store-credentials`. Updates need `SUFeedURL` and `SUPublicEDKey` set in `App/Info.plist`. Nothing is uploaded except for notarization, and only when you ask for it.

Before any public release, work through [docs/release-checklist.md](docs/release-checklist.md). Several of its checks need a person, a real Mac, and real permission prompts.

## Troubleshooting

| What you see | What to do |
|---|---|
| "Remind needs Screen Recording permission." | Use **Open Screen Recording settings…** in the menu, turn it on, and choose **Try again**. |
| "Your keychain is locked, so recordings can't be opened yet." | Unlock your login keychain, then quit and reopen Remind. Your recordings are safe. |
| "The key for your recordings is missing from your keychain." | Remind won't make a new key, because that would orphan your history. See the recovery key entry under [Known limitations](#known-limitations). |
| "Recording stopped because the disk is nearly full." | Free up some space. Recording resumes by itself above 4 GB free. |
| "Recording stopped because video encoding kept failing." | Choose **Try again** in the menu. |
| "Recording is paused because Remind kept crashing." | Choose **Try again** in the menu. The count clears after 10 minutes without trouble. |
| "Nothing recorded on this display yet" | Remind only records the display your pointer is on. |
| New recordings can't be found by their text yet | The first text recognition under a new app identity compiles Vision's models, which can take minutes. Frames wait safely in the log. |
| Ask shows moments but no written answer | It says why. Usually Apple Intelligence is off, or its model is still downloading. |
| "Accessibility is off for Remind…" in Settings → Screen | Grant Accessibility in System Settings. Without it, Remind can only spot private windows by their titles. |
| "… isn't responding to Remind…" in Settings → Screen | That browser's windows aren't being recorded until it answers again. This is deliberate. |
| "Transcription couldn't start…" | Check the language in Settings → Audio. macOS needs to download each language the first time. |
| Permissions keep resetting after rebuilds | macOS ties grants to the signature. Build with a real signing identity, and keep the same bundle ID. |
| Xcode can't find `RemindCoreFFI.xcframework` | Run `make project`. The framework is generated by `make core`. |

## Known limitations

**Check these before relying on Remind:**

- **Screen sharing is unverified.** The overlay asks macOS to keep it out of screen capture (`sharingType = .none`), but it hasn't been established that this holds on a real call. Until it is, don't open the timeline while sharing your screen, because that could expose your history. This blocks a public release.
- **A recovery key can be saved, but not yet restored.** Settings saves the key to a file, but the app has no way to read it back. If the keychain item is lost, recovery isn't currently possible from within Remind.
- **Password fields aren't special-cased.** If it's visible in an ordinary window, it's recorded.

**Known gaps:**

- **Browser calls aren't detected.** The detector recognises Google Meet, Zoom, and Teams on the web, but the app doesn't pass it web addresses yet. Use the Audio capture switch for these.
- **Star moment in the menu bar doesn't add a star yet.** It and its global shortcut make sure the next frame is kept, but don't mark it. To star a moment, use ⌘⇧S or the ⋯ menu in the timeline.
- **Private window detection depends on titles.** A language missing from the table means private windows aren't detected in it. This hasn't been checked in real browsers in each language.
- **Firefox web addresses aren't captured,** so **Open** reopens Firefox rather than the page. Private windows there are still recognised by title.
- **Only one display records at a time:** the one your pointer is on.
- **There's no list of past transcripts.** **Last transcript** opens the most recent one from the current run of the app. Older ones are reachable through search.
- **The interface is English only.** Strings are marked for localisation, but no translations exist yet.
- **Apple Silicon only.** Builds are `arm64`.

**Not yet tested with real hardware or people:** input methods in search, the overlay over full-screen apps and in Stage Manager, haptics, and the Control Center button. The [release checklist](docs/release-checklist.md) has the full list.

## Documentation

| Document | What's in it |
|---|---|
| [docs/architecture.md](docs/architecture.md) | How Remind fits together |
| [docs/PRIVACY.md](docs/PRIVACY.md) | What's recorded, where it's kept, and how to delete it |
| [docs/spikes.md](docs/spikes.md) | What's been measured, what hasn't, and what each result changed |
| [docs/release-checklist.md](docs/release-checklist.md) | Everything left to do before a public release |
| [docs/third-party-notices.md](docs/third-party-notices.md) | Third-party software and licences |

## Built with

**Languages:** Swift 6 and Rust.

**Apple frameworks:** ScreenCaptureKit, VideoToolbox, Metal, Vision, Speech, FoundationModels, AVFoundation, EventKit, App Intents, WidgetKit, and Swift Charts.

**Third-party:** SQLCipher, rusqlite, UniFFI, RustCrypto's `chacha20poly1305`, BLAKE3, zstd, rust-stemmers, rayon, crossbeam, KeyboardShortcuts, and Sparkle. [docs/third-party-notices.md](docs/third-party-notices.md) has the details. Its licence table hasn't been verified against each package yet.

## Licence

Remind is released under the [MIT License](LICENSE). Third-party software keeps its own licences, listed in [docs/third-party-notices.md](docs/third-party-notices.md).
