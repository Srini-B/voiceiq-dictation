# 2026-11-26: Meeting capture reliability fixes from Hex

## Why

Hex (anomalyco/hex, MIT) fixed several ways a Mac meeting recording lost
audio or ran on after its call. VoiceiQ had the same gaps. Each fix is
rewritten in Swift to fit VoiceiQ's recorder; no Hex UI or settings came
with them.

## What changed

- **System tap rebuild** (`5704885d`, `4a3e9d49`). `SystemAudioTap` listens
  for `kAudioHardwarePropertyDefaultOutputDevice` and watches for 15 s of
  exact zeros after the track carried sound while the tapped processes (or,
  for a global tap, the default output) still play. Either one starts a new
  tap and aggregate on the same processes, then stops the old one, writing
  into the same `system.caf`. The gap between the old tap's last buffer and
  the new tap's first is written as silence, so the system track stays
  aligned with the mic. A failed rebuild leaves the old tap running and
  retries up to five times. Before, switching headphones mid-call could
  leave the rest of the far side silent. Decisions are in
  `SystemTapWatch.swift`.
- **Call mic must have input channels** (`657aa0cf`).
  `CallDetector.processes(for:)` took the first device a call process
  listed, which can be the built-in speakers. It now takes the first with
  input channels (`kAudioDevicePropertyStreamConfiguration`, input scope).
- **Browser call ends while locked** (`092a9b33`). While the screen is
  locked, a recorded browser call counts as going only while the browser
  captures the mic (`CallProcesses.isLive`), so a browser that keeps its
  output open after the call hangs up as the Mac locks no longer keeps the
  recording running. Call apps keep their output counting.
- **Mute my mic** (`6118eb82`). A button under Stop recording in the
  Meetings window. Muted, the mic track records silence of the same length;
  the pill reads "Mic muted". It resets for every recording. No setting.
- **Aside browser** (`ae1cdf71`). `at.studio.AsideBrowser` added to
  `CallApps.browsers`, so a Meet call in Aside is offered.

- **Discard while recording** (`01e5209b`, the recording pill part). A
  quiet × beside Stop in the pill asks "Discard this recording?" with Keep
  and Discard inline; leaving the pill answers Keep. The Meetings window has
  a trash button beside Mute my mic with a confirmation dialog.
  `MeetingEngine.discardRecording()` stops capture, skips transcription and
  notes, and deletes the folder through `MeetingStore.delete` (not the
  Trash). A recording meeting never syncs, so no half-meeting reaches
  iCloud. If the delete fails, the meeting stays listed as failed with its
  audio. Before, Stop was the only way out, which sent the audio to Gemini.
- **"Keep recording" no longer shrinks** beside "Stop now" in the call-ended
  pill: both buttons are fixed-size with layout priority. The behaviour
  comes from FluidVoice `7c744b79` (GPL-3.0); this was written from the
  description alone, without reading its code.

## Not built

- **Stop a manual recording when its call ends** (`e5f6dac8`). Already the
  case: Option-M and Record pass the detected call as the recording's
  source, so the call-end countdown runs for them. A recording with no call
  detected is not stopped, as before.
- **Choose one app or output device for manual recordings** (`7364c058`).
  Manual recording starts from one button and Option-M with no choices; a
  picker would change that start flow, so it was left out.

## Verification

Pending Mac build. New tests in
`VoiceIQCore/Tests/VoiceIQCoreTests/MeetingCaptureTests.swift` cover the
silence watch, the output-moved check, the gap padding, the input-channel
filter and the locked-browser rule. The rebuild has not run against a live
output change or a live call. Discard and the pill layout have no tests (UI
and file deletion); they need a check on the installed app.
