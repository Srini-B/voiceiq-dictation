# Watching Hex and FluidVoice: first survey and batch

**2026-11-22.** cyron asked to start watching Hex again, limited to dictation,
meetings and other goodies (nothing for the iOS keyboard), and to watch
FluidVoice too. A daily check will bring later changes over on their own
branches.

## What was reviewed

| Upstream | Licence | Reviewed | Baseline for the next check |
| --- | --- | --- | --- |
| [anomalyco/hex](https://github.com/anomalyco/hex) | MIT | `2a023f91..afd7da22` (130 commits), plus older features not yet taken | `afd7da22432dc8902bdc36908457526b403632b7` |
| [altic-dev/FluidVoice](https://github.com/altic-dev/FluidVoice) | GPL-3.0 | `b60a3021..87fbef8b` (458 commits since 2026-09-01) | `87fbef8ba7b4b4c08723bd47fa989e9a94dad716` |

- **Hex** is MIT. Code may be adapted with its notice, as in PR #56.
- **FluidVoice** is GPL-3.0. VoiceiQ is Apache 2.0, so under the clean-room
  rule in `CONTRIBUTING.md` its code is not copied. Behaviour was written
  down in our own words and built from that. `THIRD_PARTY_NOTICES.md`
  credits both.

Out of scope here, because other threads own them: offline models
(Fluid Speech, Fluid 1.1 Ripple/Splash, FluidMeet), online/offline choice,
RAM gating, model downloads, and the local API/MCP.

## Built in this batch

| # | Change | From |
| --- | --- | --- |
| 1 | No blind ⌘V when focus is on a control that takes no text (button, menu, slider…); the text goes to the clipboard with "Copied — press ⌘V" | FluidVoice `51e62364`, `a1a65772` |
| 2 | Any Electron app gets its accessibility woken, found by `Electron Framework.framework` in its bundle, not only 18 listed bundle IDs | FluidVoice `5b7c4205` |
| 3 | The dictation key does nothing while the screen is locked | FluidVoice `43668220` |
| 4 | A closed MacBook lid with the built-in mic as input: "no speech" now says why | Hex `629c9256` (`src/audio/lid.rs`) |
| 5 | Dictionary wrong → right spellings applied to meeting transcripts | FluidVoice `602dcc1f`, `58274f08` |
| 6 | × on a call offer keeps that app or site quiet for 30 minutes; a timed-out offer does not | FluidVoice `MeetingAutoDetector` |
| 7 | iPhone: no swipe-to-delete on a meeting that is recording or being written up (the Mac already disabled it) | Hex `da96da03` |
| 8 | VoiceOver reads the pill's notices, errors and meeting offers; never while a dictation records | FluidVoice `8dcf4fdc`, `a0787876` |
| 9 | F13–F19 can be the dictation key or a shortcut on their own | FluidVoice `33fa5d83` |
| 10 | ⌘C copies the selected dictation in History | FluidVoice `9e3cea53` |

## Ranked list (built in the second batch, below)

Larger or a product call. In rough order of value:

1. **Stop a detected call's recording when the call ends** (FluidVoice
   `5ffc4beb`, `2e971dd6`, `12ba3c17`): after the app quits or lets go of
   its audio for 20 s, and 45 s of quiet, a 30 s "Meeting ended · Stopping
   in N s" countdown with Stop now / Keep recording. Today a forgotten
   recording runs until stopped by hand. M; needs real calls to test.
2. **Check that a ⌘V landed** (FluidVoice `fadaed91`, `caedd4ef` and
   others): read the field back at about 0.15, 0.5 and 1.5 s and offer Copy
   when nothing changed. Today a posted ⌘V counts as inserted. M.
3. **Dictate again while the last one is still being written** (Hex
   `parakeet.rs` ordered outputs): a press during transcribing is refused
   silently today. L; a small first step is a sound and a hint on the
   refused press.
4. **Sound volume slider** (Hex `7b11beb8`, default 50 %). S, adds a setting.
5. **Press Return after the paste**, per app (Hex YOLO mode, FluidVoice
   auto-send). S–M, a product call.
6. **iPhone microphone choice** Automatic / iPhone / Bluetooth (Hex
   `d23acdf8`). S–M; touches the keep-alive.
7. **Reject a model reply that answers or adds a preamble** (Hex `6f0b20c1`).
   M; needs a `heard` field in the one-call schema, so measure the cost first.
8. **Calendar-aware meeting titles and attendees** (Hex `src/calendar.rs`). L.
9. **Mouse side buttons, hold Space to mute, pinned dictations, spoken
   emoji, case-sensitive dictionary rules, far-side-silent warning, pausing
   any media.** Maybes, each M or a product call.

Skipped: Hex's 200–600 ms release tail (conflicts with stop-at-key-up,
2026-11-20), returning to the original app before pasting and
restoring the starting field (both declined before), per-service "always
record" (detection only offers), hold-to-talk (removed on purpose), per-app
prompts, a 32 MB clipboard-backup cap (the snapshot has to read the data to
size it, so it saves little), meeting delete to the Trash (iCloud deletes
and Put Back would fight).

## Second batch: the eight ranked items

cyron asked for all eight, with Press Return after pasting as a setting that
is off by default. Same clean-room rule for FluidVoice. The seventh, the
reply and preamble guard, was built and then removed at cyron's call (below),
so seven shipped in the PR.

| # | Change | Where | From |
| --- | --- | --- | --- |
| 1 | Detected call ended: 20 s without the call's sound and 45 s of quiet, then "Meeting ended · Stopping in 30s" with Stop now / Keep recording | Mac | FluidVoice (behaviour) |
| 2 | Read the field back after ⌘V; a certain miss copies the text and says so | Mac | FluidVoice (behaviour) |
| 3 | Dictate again while the last one is still being written; texts insert in spoken order | Mac | Hex |
| 4 | Sound volume slider (default stays at the old 90 %) | Mac (iPhone plays no sounds) | Hex |
| 5 | Press Return after pasting, off by default, every app or chosen apps; Esc after you stop skips it | Mac (the iPhone keyboard is frozen) | Hex |
| 6 | iPhone microphone: Automatic / iPhone / Bluetooth; the warm session stays on the iPhone's mic | iPhone | Hex |
| 8 | Calendar: meeting title and invitees, off until connected | Mac and iPhone | Hex |

### Decisions

- **Volume default 90 %**, not Hex's 50 %: that was VoiceiQ's fixed level,
  so nobody's sounds change.
- **Press Return after pasting is off** (cyron). With no apps chosen it applies
  everywhere; adding apps limits it.
- **Concurrent dictation** covers a press while the last dictation is
  transcribing. The few tens of milliseconds of finalizing and inserting
  still refuse a press. iPhone dictation is unchanged.
- **Call end** counts only recordings started from a detected call. A
  browser call ends only once the browser plays no sound at all, so a
  YouTube tab keeps the recording going (it can be stopped by hand).
- **Meetings on iPhone always use the iPhone's mic.** The Meetings screen
  already says so; the old "prefer built-in mic: off" used to route them to
  AirPods.
- **Calendar** asks for access only when the switch is turned on; only the
  event's title and invitees are read, and they go to Gemini with the notes
  request.
- **Reply and preamble guard removed** (cyron). It asked Gemini for a
  verbatim `heard` field next to `text` (2.83 → 3.06 s mean, 45 → 79 output
  tokens per dictation, measured on six synthesized dictations) and inserted
  `heard` when the text looked like an answer. Review found 13 kinds of
  correct cleanup it rejected (spelled-out words, lists, units, restarted
  phrases, Chinese and Japanese, …), and the released cleanup already
  works, so the dictation request and prompt stay exactly as in 0.7.12. The
  daily upstream watch no longer proposes it.
- **Not built:** FluidVoice's lazy clipboard "read receipt" for the paste
  check, the Meet "You left the meeting" page check, and Hex's calendar
  reminders before a meeting starts.

## Verification

- `swift test --package-path VoiceIQCore` and the unsigned Mac and iPhone
  builds run in CI on this branch's PR.
- New tests: meeting transcripts get the dictionary's spellings with
  speakers and times unchanged; bare F13 matches with the fn flag and
  ⌘F13 does not; Electron detection from a bundle's frameworks.
- Not run on a signed build yet. The lock screen, a closed lid, VoiceOver
  and a focused button need a person at a Mac; see the PR's test plan.
