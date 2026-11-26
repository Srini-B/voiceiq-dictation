# Pasting on macOS 27.3

2026-11-26. Not released.

## Why

macOS 27.3 split the old Accessibility grant. Accessibility still lets
VoiceiQ watch the dictation key and read and set fields, but posting key
events (the synthetic ⌘V, Return after pasting, typed text for Windows App
and Chromium 155–156) now needs System & App Protection Override. Without
it `AXIsProcessTrusted()` still reads true and `CGEvent.post` drops every
event without an error, so setup read Ready and VoiceiQ reported a paste
that never landed. Hex hit the same thing and fixed it in `341046f8`; it
names the list per version in `0744db0d` (anomalyco/hex, MIT).

## What changed

- `KeystrokeAccess` (VoiceIQCore, InsertionEngine): on 27.3+ VoiceiQ may
  post key events only when `CGPreflightPostEventAccess()` says so; below
  27.3 nothing changes. `isReady` is Accessibility plus that, and is what
  onboarding, Settings → Dictation → Permissions, the first-run check and
  the menu-bar status read. Accessibility stays required: the event tap and
  tier-1 inserts still need it.
- `PasteInserter.paste`, `TypingInserter.type` and `ReturnAfterPaste` refuse
  before touching the clipboard or posting anything. The coordinator then
  falls back to the clipboard as it already did when a ⌘V could not be
  posted: the text is on the clipboard and in History, Paste last transcript
  still has it, and the pill says "Copied — allow VoiceiQ in System Settings
  → Privacy & Security → System & App Protection Override" with the error
  tone, for a dictation, a background one and Paste last transcript. A
  skipped Return after a tier-1 insert is only logged.
- Grant (onboarding) and Open System Settings (Settings) also call
  `CGRequestPostEventAccess()` on 27.3+, so macOS lists VoiceiQ and posts
  its Privacy & Security notification.
- The permission is named for the running version: "Accessibility" below
  27, "Device Control and Data Access" on 27.0–27.2, "System & App
  Protection Override" on 27.3+.
- The preflight keeps its launch-time answer, so a grant needs one restart.
  Onboarding's existing stale-grant line (after 10 s) now has the Restart
  VoiceiQ button experience.md always described, and on 27.3 says "Allowed
  it? macOS applies it after a restart." The Settings row offers Restart
  VoiceiQ when Accessibility is on but posting is not. The menu bar reads
  "To paste, allow VoiceiQ in System & App Protection Override and restart
  it" while the key and tier-1 inserts keep working. There is no
  one-restart marker as in Hex: VoiceiQ never restarts on its own, so a
  grant that never lands cannot loop.
- Test: `KeystrokeAccessTests` (the 27.3 cut-off for posting, the list name
  for each version).
- Docs: `docs/design/architecture.md` (InsertionEngine), the S4 card in
  `docs/design/experience.md`; Hex attribution in `THIRD_PARTY_NOTICES.md`.

Hex range `db515bda..012bdbbe`, paste, keyboard and permission-guide files:
`341046f8` and `0744db0d` are used here. `616f1a32` is a refactor of Hex's
own output policy and has nothing to port.

## Checked

Pending Mac build: `swift test --package-path VoiceIQCore` and the VoiceIQ
and VoiceIQiOS builds. Not run on a macOS 27.3 Mac: whether the
`Privacy_Accessibility` anchor opens System & App Protection Override,
whether the request posts its notification, and that a grant reads true only
after a restart come from Hex's notes, which say the same is unverified
there.
