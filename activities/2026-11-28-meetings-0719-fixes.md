# Meetings fixes from the 0.7.18 gate, for 0.7.19 (2026-11-28)

Neon's release-gate pass on the 0.7.18 branch (agy session b80ee9db, at
83e953f) found meeting issues that main shares. 0.7.18 ships Gemini from
`release-0.7.18-gemini`, so these land on main, worded for AssemblyAI.

## What changed and why

- **Waiting meetings while offline.** The retry timer kept going offline,
  re-encoding the audio and repeating the notice every 5 to 60 minutes. It is
  no longer scheduled while offline; coming back online sends the meeting and
  resets the backoff to 5 minutes; a timer armed before a network change is
  cancelled. Ports of 8a49c58 and 8d21588.
- **Former On device users.** An automatic update shows no release notes, so a
  0.7.17 user who had set Meetings to On device
  (`meetingTranscriptionSource == "onDevice"`) gets one notice on their first
  recording: meetings now go to AssemblyAI, and discarding the recording keeps
  it off AssemblyAI. The key is then removed. The notice stays on the pill as
  recording starts and is short enough to fit it; the iPhone recorder gets the
  Discard it names. Ports of 8a49c58, 0300d86 and 8d21588.
- **Pill and banners.** A recording started from the Meetings window shows the
  pill, Mute leaves a notice up, and an iPhone banner's timer restarts with its
  text. Port of 8d21588.
- **iPhone, failed redo of a finished note.** The old notes hid the failure
  card, and Redo needed `.done`, so nothing could retry it. The failure card now
  shows above the notes, and More offers Retry while the note is failed, as the
  Mac's menu does.
- **Notes-step wording.** A failure while writing notes said the recording is
  "transcribed". `MeetingFailure.reason(for:step:)` and the notices now say the
  transcript is saved and the notes are written.
- **`get_meeting` with `from`/`to` on an empty transcript** no longer returns
  the "no times" note; there is nothing to leave out.
- **Titles.** The Markdown export and the iPhone note header, share name and
  file name use `displayTitle`, so an empty notes title falls back to the
  calendar event's, as the list does.
- **Markdown folder ledger.** A failed write after switching folders erased the
  previous folder's entry, so switching back made a duplicate "… 2.md". The
  entry is now restored.

Already on main: retry after a non-waiting notes failure regenerates notes
(`failedStep`), which Neon's High #1 asked for.

## Verification

See the PR for the Mac mini runs (`swift test`, both app builds) and the
Neon agy pass.
