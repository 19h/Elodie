# Getting Elodie onto the Mac App Store

The App Store only takes sandboxed apps, so Elodie has a second edition for it, built from the same
code. `make app-store` builds it and checks the result. Nothing here uploads anything.

## What the App Store edition leaves out

macOS doesn't let a sandboxed app read other apps through Accessibility. This was tested on macOS
27.2: with the permission granted, `AXIsProcessTrusted()` says yes, and every read still fails with
error -25204. So this edition has none of that code.

| | Direct download | App Store |
|---|---|---|
| Web addresses on recordings | Recorded, except in Firefox | Not recorded, so **Open** returns to the browser and not the page |
| Arc | Recorded, with private windows left out | Not recorded, because its private windows can't be recognised |
| Other browsers' private windows | Left out, by title and Accessibility | Left out, by title |
| Calls in a browser | Noticed from the address | Not noticed, but transcribing can be started by hand. Zoom, Teams, Slack, and Webex apps are |
| ⌘⇧ and scroll | The app underneath stays still | Opens the timeline, but that first swipe also reaches the app underneath |
| Opening at login | Comes back after a crash | Doesn't come back by itself |
| Network | No code for it | No code for it, and macOS blocks it too |
| Updates | Replace the app with a newer one | The App Store |

## What's been checked

`scripts/check-bundle.sh`, which `make app-store`, `make release`, and `make distribute` all run, fails if the bundle has
an updater, test code, networking calls, a network entitlement, a symbol outside the public SDK, a
private framework, or no privacy manifest. For the App Store edition it also fails without the
sandbox, or with a temporary exception, Accessibility, an event tap, or a launch agent.

Real runs of the sandboxed edition on this Mac, with screen recording granted:

| What | Result |
|---|---|
| Recording a window, through to searching its text | 12 frames stored, and 11 hits for a word in them |
| Frames from a browser | Kept, with Accessibility reporting as granted |
| Encoding, the vault, and decoding | The same speed as outside the sandbox: 26.4 ms median to the first new frame, against 25.7 ms |
| The overlay on a real display | Opened with the recorded picture. Search found 30 hits, and choosing one showed its 2 highlights on the word |
| Star, select a run, and delete it | Worked, taking search from 30 hits to 0, and recording carried on |
| Saving through real save panels, to a folder outside the sandbox | An image, a video, and the recovery key all saved, and replacing an existing file worked too. The key file stayed private to you (`-rw-------`) |
| Transcribing the computer's audio | Test speech came back as words, labelled Others |
| The microphone | 2,819 buffers arrived, and recognition got 523,650 frames. Nobody was speaking, so it produced no words |
| Control Center's signalling, and the state it reads | Pause and resume worked from another process, and the state went 1, 2, 1 |
| The swipe, with synthetic trackpad events and no permissions | Opened the timeline and moved back to 14 seconds ago, carrying on after the keys were let go and through momentum |
| Choosing a file in an open panel | Read a text file from outside the sandbox. The panel for choosing an app also comes up and stays up |
| Opening at login | Registers as enabled, and unregisters cleanly, without starting a copy |
| Keychain, hotkeys, the on-device model | Worked |
| Connecting to the internet | Blocked |

**Still needs a person:** seeing the switch in Control Center's gallery and flipping it, a real voice
through the microphone, how the swipe feels on real fingers with ⌘⇧ (the test used other keys, because
another copy was holding those), pressing Open on a chosen app, whose list can't be reached by
automation, and opening at login across a restart.

These ran on the capture stream Elodie used before. Since it moved to separate pictures, `--spike endtoend`
has been run again in the sandboxed edition, on a harness window, and passed. The rest haven't been repeated.

## Identifiers

Both editions are `com.kenansulayman.elodie`, with `com.kenansulayman.elodie.controls` for the Control
Center extension, and `.dev` on both for development builds. Only those two need registering, and they
are. The App Store edition keeps its key under `com.kenansulayman.elodie.appstore.vault`, so it never asks
for the direct download's key on a Mac that has both.

The extension has no provisioning profile. Apple says nested code doesn't need one if it only has
unrestricted entitlements, like the sandbox, and it's the main app that has to have one for TestFlight. If an
upload warns with ITMS-90889 and names the extension, Apple's suggested fix is to add Keychain Sharing to
that target, which forces a profile.

## Which build to upload

Upload `build/app-store/export/Elodie.pkg`, using Transporter, or archive the **Elodie App Store** scheme in
Xcode. The **Elodie** scheme is the direct download, which has no sandbox, so Apple refuses it with "App sandbox
not enabled". In Transporter, remove any earlier attempt and add the package again.

Apple also refuses a build made with a beta Xcode or SDK, with error 90301, so it needs a release Xcode.
`scripts/check-bundle.sh` fails on a beta build before you get as far as uploading it.

## What only you can do

1. **Answer the encryption question for each build.** The build doesn't declare anything, so App Store
   Connect asks after each upload, and the build shows as missing compliance until you answer. Elodie encrypts
   with its own libraries, so the honest first answer is yes. It may qualify as exempt, since encryption only
   protects your own data and isn't its purpose, but claiming that wrongly is your liability, and Apple also
   names secure storage as something France controls. Ask a lawyer. Once you know, `ITSAppUsesNonExemptEncryption`
   in `App/Info.plist` can answer it for every build. Don't set it to `true` without Apple's compliance code as
   well, because the upload is refused with "Invalid Export Compliance Code".
2. **Get the rest of the legal review:** a trademark search on "Elodie", the decompiled reference app,
   and recording law. See [release-checklist.md](../release-checklist.md).
3. **Sign in to Xcode with your developer account,** then run `scripts/app-store.sh --export`. It signs with
   Apple's cloud-managed distribution certificates, so none need installing on this Mac, and leaves the
   package to upload in `build/app-store/export`. This worked on 2026-11-06, but the package hasn't been
   uploaded, so Apple hasn't validated it yet.
4. **Create the app in App Store Connect,** and declare your EU trader status. It's required, and if
   you're a trader your address, phone number, and email go on the product page in the EU.
5. **Upload** from Xcode's Organizer or Transporter, try it through TestFlight, and submit it.
6. **Finish the checks in [release-checklist.md](../release-checklist.md)** that need a person, above all
   screen sharing on a real call.

## Before building much more: ask App Review

No always-on screen recorder turned up on the App Store, approved or rejected, so this could be refused
on judgement however good the build is. Guideline 2.5.14 asks for explicit consent and a clear
indication while recording, which Elodie has. It's worth asking first, for example:

> Elodie is a Mac app that records the user's screen every few seconds, reads the text on it, and lets
> them search and scroll back through it. Everything stays encrypted on the Mac, and the app has no
> network access at all. Recording starts only after the user turns it on in a first-run window, a menu
> bar icon always shows whether it's recording. Users can pause, exclude apps, and delete anything. Is continuous screen recording of this kind, with that
> consent, acceptable under guidelines 2.5.14 and 5.1.1?

## The listing

**Name:** Elodie  
**Subtitle:** Search everything you've seen  
**Category:** Productivity  
**Price:** Free  
**Privacy policy:** https://github.com/19h/Elodie/blob/master/docs/PRIVACY.md  
**Support:** https://github.com/19h/Elodie/issues  
**Keywords:** screen,history,search,recall,memory,timeline,OCR,transcript,meeting,private

**Description:**

> Elodie records your screen as you work, reads the text on it, and lets you find anything you've seen.
>
> Scroll back through your day as if you were scrubbing a video of your screen. Search for a word you
> half remember, and go straight to the moment it was on screen. Ask a question in plain language, and
> get an answer from Apple's on-device model, with links to the moments it used.
>
> Everything stays on your Mac. Recordings are encrypted, and Elodie has no account, no analytics, and
> no way to connect to the internet. macOS enforces that last part.
>
> • Timeline: scroll through time in a full-screen view that opens without switching apps
> • Search: every word on your screen, indexed on your Mac
> • Ask: answers with sources, from Apple's on-device model
> • Daily Recap: where the day went, by app and by hour
> • Meetings: optional transcripts of your microphone and computer audio
> • Control: pause any time, exclude apps, leave out private browser windows, and delete any stretch
>
> Transcribing a meeting can require everyone's consent where you live. Getting it is up to you.
>
> Requires an Apple silicon Mac. Ask requires Apple Intelligence to be turned on.

**Screenshots:** `docs/app-store/screenshots`, from `make app-store-screenshots`. They're 2880 × 1800,
with fixture data, so the text on them is random words. You may want better scenes for the listing.

**App Privacy:** Data Not Collected. Apple says data processed only on the device isn't collected, and
Elodie sends nothing anywhere.

**Age rating:** answer the questionnaire yourself. Elodie shows whatever was on the screen, with no
content of its own.

**App Review notes:**

> Elodie needs Screen Recording to work. After granting it, macOS may ask you to quit and reopen the app,
> and Elodie offers a button for that. There's no account. Use the app for a minute or two, then press
> ⇧⌘Space to see the timeline, and search for a word that was on screen. Transcribing is off unless you
> turn on Audio capture in the menu bar. Elodie's sandbox has no network entitlement, by design.
> Ask needs Apple Intelligence, and says so if it's off.

## Risks that can't be fixed from here

- **macOS's repeated screen recording confirmation stays.** The one entitlement that might remove it,
  Persistent Content Capture, is documented for remote-desktop apps, and it's unknown whether Apple would grant it here.
- **An obsolete call takes the pictures.** `CGWindowListCreateImageFromArray` is in the SDK's public list
  of symbols, but the headers mark it obsolete since macOS 15, so Elodie looks it up by name. App Review
  could question that, and a later macOS could remove it. The alternative, ScreenCaptureKit, is what
  showed the indicator and darkened streaming video.
- **An undocumented dictionary key.** Elodie reads `CGSSessionScreenIsLocked` from the public
  `CGSessionCopyCurrentDictionary()` and listens for `com.apple.screenIsLocked`, because there's no
  public way to ask whether the screen is locked. They aren't private symbols, and they're how Elodie
  stops recording at the lock screen, so they've stayed.
- **The swipe.** One developer reports an active event tap working in a sandboxed App Store app with
  Input Monitoring in place of Accessibility, which could keep the app underneath still. It hasn't been
  tried, because it needs someone to switch that permission on, and its prompt talks about keystrokes.
