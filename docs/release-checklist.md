# Before a public release

## Decisions only you can make

- [ ] **Name.** "Remind" is used by a school-messaging app, and it sits close to Apple Reminders
      in Spotlight. Get a trademark check.
- [ ] **Bundle ID.** `app.remind.Remind.dev` in `project.yml` is a placeholder. Changing it after
      release orphans keychain items and permission grants, so choose before shipping.
- [ ] **Legal review.** The behaviour was informed by analysing a decompiled commercial app, whose
      licence may restrict that. This repository keeps that material out, and uses its own code and
      wording, but that doesn't settle the question.
- [x] **Licence** for Remind itself: MIT.
- [ ] **Hosting** for the update feed and disk image.

## Setup

- [ ] Generate a Sparkle signing key, and set `SUPublicEDKey` and `SUFeedURL` in `App/Info.plist`.
      Until those are set, builds have no updater.
- [ ] Store notarization credentials: `xcrun notarytool store-credentials`.
- [ ] Decide on the keychain. The data protection keychain needs a provisioning profile and a
      registered App ID, and it would add "this device only, after first unlock" protection. The
      login keychain works today. See docs/spikes.md.
- [ ] Update `docs/third-party-notices.md` for the final dependencies.

## Checks that need a person

Automated tests can't cover these. Each needs a real Mac and real prompts.

- [ ] First run on a clean account: permission prompts, Quit & Reopen, restoring the same step.
- [ ] macOS asking to confirm screen recording again: recording pauses, the gap shows, and it resumes in one click.
- [ ] **Screen sharing: does anyone on a call see the overlay?** If `sharingType = .none` doesn't
      hold, opening the timeline during a share would expose your history. Spike 7. **Don't ship until this is known.**
- [ ] Input methods in search: Pinyin, Kotoeri, Korean, emoji, including where candidates appear.
- [ ] Overlay over full-screen apps, in Mission Control, with Stage Manager, on a notched display, and on a second display.
- [ ] Private windows in real browsers, in each language you claim to support.
- [ ] Haptics while scrubbing.
- [ ] Transcribing a real meeting with a real microphone.
- [ ] The Control Center button: it appears, and it pauses and resumes.

## Measurements still needed

- [ ] `make bench`-style budgets on an M1 or base MacBook Air. Everything so far ran on an M4 Max, which flatters them.
- [ ] A real week of daily use, for storage per day. Every storage figure so far comes from a synthetic screen.
- [ ] Energy with `sudo powermetrics`.
- [ ] Search scaled past 800,000 frames, if a larger scratch disk is available.

## Final

- [ ] `make test` and `make torture` pass.
- [ ] `make release`, then notarize with `scripts/release.sh --notarize <profile>`.
- [ ] Install from the disk image on a clean Mac.
