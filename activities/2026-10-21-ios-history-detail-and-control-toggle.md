# iOS History detail, Control Center toggle, clipboard log

2026-10-21.

## Why

The owner uses an iPad with a keyboard case and dictates from the Control
Center control. They reported five things:

1. In History on iPad, picking the newest dictation highlighted it on the
   left, but the right side kept showing the previous one until the app was
   restarted.
2. Copy in the dictation detail gave no sign that it worked.
3. The iPhone and iPad detail did not show the models and cost that the Mac
   shows.
4. The Control Center button lit up for a moment and then went back to off
   while the dictation was still recording. Only the status-bar mic dot
   showed the session.
5. The result did not land on the clipboard, and the session banner went away
   after a few seconds.

## What changed

- History: the split view's detail is keyed by the dictation id. Without the
  key, SwiftUI reused the first detail's `@State` record for every row picked
  after it.
- History detail: Copy shows "Copied" with a checkmark and a success haptic
  for 1.5 s. The Session log's Copy does the same.
- History detail: a Cost row and one row per model call, with the stage, the
  model and the cost, from the usage ledger. This matches the Mac.
- Control Center: the control is a toggle (`ControlWidgetToggle`), on while a
  dictation records. The app reloads it whenever recording starts or stops. A
  press runs `SetDictationIntent`, which acts only when the requested state
  differs from the real one.
- Clipboard: `copyIfNotTyped` now logs whether the write took effect and
  whether the app was in the foreground or the background. Before, it logged
  "copied" whatever happened.

## Not changed

- The Live Activity banner on iPad. An iPad has no Dynamic Island, so iPadOS
  shows the activity as a banner for a few seconds and then keeps it on the
  Lock Screen only (Apple's ActivityKit documentation). An app cannot pin the
  banner. The Control Center toggle now shows the session and stops it.
- The clipboard cause is not known yet. The copy path ran in the simulator
  on 2026-09-28, but it has never been checked on a physical iPad. The new log
  line will tell whether iOS refused the background write, or whether the
  copy path never ran.
- A result cannot be typed into the focused field: iPadOS does not run
  third-party keyboards while a hardware keyboard is attached.

## Verification

- `VoiceIQiOS` Debug build for the iPad Air 11-inch (M4) simulator succeeded.
  `extract.actionsdata` lists `SetDictationIntent`.
- Two dictations seeded on the simulator (meta.json folders plus usage rows),
  driven with `axe`:
  - The build without the id key reproduced the bug: the second row was
    selected, and the detail still showed the first.
  - With the key, the detail followed each pick.
  - The first dictation showed Cost $0.0017, Transcription gemini-3.5-flash ·
    $0.0004 and Cleanup gpt-6-astra · $0.0013. The local one showed
    fluid-speech-mini · $0.0000.
  - Copy turned into "Copied" with a checkmark, and `simctl pbpaste` returned
    the text.
- `scripts/test.sh`: 143 tests, 0 failures.
- Not verified: the Control Center toggle on screen, and the clipboard on a
  physical iPad. The simulator's Control Center had no VoiceiQ control added,
  and no device was connected.
