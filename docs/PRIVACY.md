# Remind and your privacy

**Remind keeps everything on your Mac.** It has no account, no analytics, and no crash reporting,
and it doesn't upload your recordings, text, or transcripts anywhere.

## What it records

- **Your screen:** a picture every 2 seconds or so, when the screen has changed, from the display
  your pointer is on.
- **The text on your screen,** read on your Mac.
- **The app, window title, and web address** of what's in front.
- **What's said, if you turn it on:** a transcript of your microphone and your computer's audio.
  The audio itself isn't kept.

## What it leaves out

- Apps you exclude in Settings.
- Private and incognito browser windows. This relies on browsers' window titles, in languages
  Remind knows. If a browser doesn't answer in time, Remind drops the frame.
- Remind's own windows.

**Password fields and other sensitive content in ordinary windows do get recorded** if they're
visible on screen. Exclude apps you don't want recorded.

## What it reads to work

- **Scrolling, to open the timeline.** With Accessibility on, Remind watches scroll events so that
  ⌘⇧ and scrolling up can take over from the app underneath. It sees scroll events only, never the
  keyboard, and it passes along everything except that gesture.
- **Your calendar, only if you turn it on.** Remind reads the title of the event happening now, to
  name a meeting. The title stays on your Mac with the transcript.

## Where it's kept

Recordings are encrypted with a key in your login keychain, in
`~/Library/Application Support/<Remind's identifier>/vault`. They're excluded from Time Machine,
because a backup couldn't be read without that key anyway. If you lose the key, your history can't
be recovered, so Settings can save a recovery key.

Anyone who can use your Mac while you're logged in can open Remind and see your history.

## Deleting

Deleting removes the recordings and their text from Remind's files, and whole chunk files are
removed from disk. A few frames just after a deleted period also go, because they can't be
decoded without what came before. Like any file deletion, old encrypted blocks can stay on the
drive or in APFS snapshots until they're overwritten.

## The network

Remind uses the network for one thing: checking for updates, which you can turn off in Settings.
That check sends your Mac's standard update request and nothing from your recordings. A build check
(`scripts/check-privacy.sh`) confirms that nothing else in Remind can use the network.

macOS downloads its own language models for transcription and Ask. Remind doesn't send anything in
that process. Ask uses Apple's on-device model, and your questions and screen text stay on your Mac.

## Recording other people

Laws on recording conversations differ by place, and many require everyone's consent. Remind asks
before transcribing a meeting unless you change that setting. Getting consent is up to you.
