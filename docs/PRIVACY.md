# Elodie and your privacy

**Elodie keeps everything on your Mac.** It has no account, no analytics, and no crash reporting,
and it doesn't upload your recordings, text, or transcripts anywhere. Nobody else, including whoever
makes Elodie, can see them, and nothing is collected or shared with anyone.

There are two editions, which differ in what they can read. The App Store edition runs in Apple's
App Sandbox, so it can't read other apps through Accessibility. Where this says that it differs.

## What it records

- **Your screen:** a picture every 2 seconds or so, when the screen has changed, from the display
  your pointer is on.
- **The text on your screen,** read on your Mac.
- **The app, window title, and web address** of what's in front. The App Store edition doesn't
  record web addresses.
- **What's said, if you turn it on:** a transcript of your microphone and your computer's audio.
  The audio itself isn't kept.

Elodie takes separate pictures rather than running a capture stream, so macOS shouldn't show its screen
sharing indicator while Elodie records, and Elodie's menu bar icon may be the only sign that it is. That
still has to be confirmed on real services. Transcribing does use a stream, so macOS can show its
indicator then.

## What it leaves out

- Apps you exclude in Settings, and their sound in a transcript.
- Private and incognito browser windows. This relies on browsers' window titles, in languages
  Elodie knows. A browser window with no title yet counts as private until it has one, and if a
  browser doesn't answer in time, Elodie drops the frame. Each picture holds only the windows Elodie
  chose just before taking it, so a private window that opens after that can't be in it, however
  briefly it's open.
- Elodie's own windows.

**Password fields and other sensitive content in ordinary windows do get recorded** if they're
visible on screen. Exclude apps you don't want recorded.

## What it reads to work

- **Scrolling, to open the timeline.** Elodie watches scroll events so that ⌘⇧ and scrolling up can
  open it. It sees scroll events only, never the keyboard. With Accessibility on, in the direct
  download, it can also take over that gesture from the app underneath, and it passes along everything
  else.
- **The front browser tab's address, while your microphone is in use.** This is how the direct download
  recognises a call in a browser. Nothing is read for this while the microphone is off, and the App
  Store edition doesn't read it at all.
- **Your calendar, only if you turn it on.** Elodie reads the title of the event happening now, to
  name a meeting. The title stays on your Mac with the transcript.

## Where it's kept

Recordings are encrypted with a key in your login keychain, in
`~/Library/Application Support/<Elodie's identifier>/vault`, or in the app's own container in the App
Store edition. They're excluded from Time Machine,
because a backup couldn't be read without that key anyway. If you lose the key, your history can't
be recovered without a recovery key. Settings can save one to a file, and if the key is ever lost,
Elodie asks for it. Anyone with that file and your recordings can read them, so keep it somewhere safe.

Anyone who can use your Mac while you're logged in can open Elodie and see your history.

The Control Center switch talks to Elodie through system notifications, and any app can use them too.
Another app can see whether Elodie is recording, and can ask it to pause or resume. It can't read your
recordings this way.

## Deleting

You can delete a stretch on the timeline, a time range, everything recorded from one app, or
everything at once. Deleting removes the recordings and their text from Elodie's files, and whole
chunk files are removed from disk. A few frames just after a deleted period can also go, because
they can't be decoded without what came before, and the timeline tells you before you confirm. Like
any file deletion, old encrypted blocks can stay on the
drive or in APFS snapshots until they're overwritten.

## The network

Elodie doesn't use the network, and it has no code that could: no account, no telemetry, and no
update check. A build check (`scripts/check-privacy.sh`) fails if any of that changes. In the App
Store build macOS enforces it as well, because the app has no permission to make a connection.

macOS downloads its own language models for transcription and Ask. Elodie doesn't send anything in
that process. Ask uses Apple's on-device model, and your questions and screen text stay on your Mac.

## Changing your mind

You're in charge of all of this, and you can stop at any time:

- **Pause or stop recording** from the menu bar or Control Center, or quit Elodie.
- **Withdraw permission** in System Settings → Privacy & Security. Elodie stops recording your screen
  or your microphone straight away.
- **Delete what's been kept,** as above. Settings → Storage has a choice to delete everything, and
  how long to keep recordings, which is how they're removed automatically.
- **Remove Elodie.** Delete everything in Settings first, then delete the app.

Nothing is held anywhere else, so there's nothing to ask anyone to delete.

## Questions

Ask at https://github.com/19h/Elodie/issues.

## Recording other people

Laws on recording conversations differ by place, and many require everyone's consent. Elodie asks
before transcribing a meeting unless you change that setting. Getting consent is up to you.
