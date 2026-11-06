# Before a public release

## Decisions only you can make

- [ ] **Name.** Get a trademark check for "Elodie". A search of the US App Store found no app with that
      name on 2026-11-06, but that isn't a trademark search.
- [ ] **Bundle ID.** `app.elodie.Elodie.dev` in `project.yml` is a placeholder. Changing it after
      release orphans keychain items and permission grants, so choose before shipping.
- [ ] **Legal review.** The behaviour was informed by analysing a decompiled commercial app, whose
      licence may restrict that. This repository keeps that material out, and uses its own code and
      wording, but that doesn't settle the question.
- [x] **Licence** for Elodie itself: MIT.
- [ ] **Hosting** for the update feed and disk image.

## Setup

- [ ] Store notarization credentials: `xcrun notarytool store-credentials`.
- [ ] Decide on the keychain. The data protection keychain needs a provisioning profile and a
      registered App ID, and it would add "this device only, after first unlock" protection. The
      login keychain works today. See docs/spikes.md.
- [ ] Update `docs/third-party-notices.md` for the final dependencies.

## Checks that need a person

Automated tests can't cover these. Each needs a real Mac and real prompts.

- [ ] First run on a clean account: permission prompts, Quit & Reopen, restoring the same step.
      A `--sandbox` run on one Mac covered the permission rows and resuming at the same step. See
      docs/spikes.md. The prompts on a clean account, and Quit & Reopen, are still to do.
- [ ] macOS asking to confirm screen recording again: recording pauses, the gap shows, and it resumes in one click.
- [ ] **Screen sharing: does anyone on a call see the overlay?** If `sharingType = .none` doesn't
      hold, opening the timeline during a share would expose your history. Spike 7. **Don't ship until this is known.**
      `--spike sharing` now captures the display from a separate process and finds nothing of the overlay,
      by screenshot, stream, or asking for that window alone, while an ordinary panel shows up every time.
      The `screencapture` tool and Chrome's real `getDisplayMedia` don't see it either.
      What's left is a real share, in the call apps people use.
- [ ] The swipe, on a trackpad and on a mouse: ⌘⇧ and scroll up. It should look like your screen going
      back in time: no flash, no jump, the first movement counted, and the app underneath perfectly
      still. `make interaction-test` covers the logic, and with synthetic events through the real event
      tap, none reached the app underneath. Only your eyes can judge the illusion.
- [ ] Scroll speed at the start of the swipe. `TimelineZoom.defaultPointsPerSecond` sets how far a
      movement goes, and it hasn't been tried on real fingers.
- [ ] Login item: turn it on, restart, and confirm the app comes back. Force quit it and confirm launchd
      relaunches it. Crash it three times and confirm it comes back paused and says why.
      Registering it, and launchd bringing it back after a SIGKILL, have worked for real. Coming back after a
      restart hasn't been tried. See docs/spikes.md.
- [ ] Pointer following: move between displays and confirm recording follows after about 2 seconds.
      The real first run saw recording follow the pointer, but didn't record how long it took.
- [ ] Dragging a frame out of the timeline into Finder and another app.
- [ ] Input methods in search: Pinyin, Kotoeri, Korean, emoji, including where candidates appear.
- [ ] Overlay over full-screen apps, in Mission Control, with Stage Manager, on a notched display, and on a second display.
- [ ] Private windows in real browsers, in each language you claim to support.
- [ ] Haptics while scrubbing.
- [ ] Transcribing a real meeting with a real microphone. Real audio reaches speech recognition, and speech in
      the microphone's format becomes words in a test, but no real voice has been tried.
- [ ] The Control Center switch: it appears, shows whether Elodie is recording, pauses and resumes, and says
      Not recording after Elodie is force quit. A sandboxed process has read the state and paused and resumed
      the app, but the switch hasn't been seen in Control Center itself.

## Measurements still needed

- [ ] `make bench` on an M1 or base MacBook Air. Everything so far ran on an M4 Max, which flatters it.
- [ ] Hotkey to first pixel and Esc to hidden, on real displays. `make bench` covers scrubbing only.
- [ ] A real week of daily use, for storage per day. Every storage figure so far comes from a synthetic screen.
- [ ] Energy with `sudo powermetrics`.
- [ ] Search scaled past 800,000 frames, if a larger scratch disk is available.

## Final

- [ ] `make test` and `make torture` pass.
- [ ] `make release`, then notarize with `scripts/release.sh --notarize <profile>`.
- [ ] Install from the disk image on a clean Mac.
