# 2026-11-26: Edit and delete meeting transcript lines

## Why

A meeting transcript could only be read. A misheard name or a line of
off-topic chatter stayed in the transcript, in Export, in questions about the
meeting and in what coding agents read, with no way to fix it short of
hearing the whole meeting again. Hex (`anomalyco/hex` at `e67eec00`) added
deleting transcript lines, and FluidVoice (`altic-dev/FluidVoice` at
`c81c83cd`, studied for behaviour only under the cleanroom policy) offers
editing a paragraph's words. VoiceiQ now does both, inside its own
transcript views.

## What changed

- `TranscriptSegment` is `Identifiable`. Its `id` is a hash of the line's
  content until the line is edited; an edited line, or an exact repeat of an
  earlier line, keeps its id in `transcript.json` (`savedID`). Transcripts
  that were never edited stay byte for byte as they were, so their sync
  digests do not change and nothing is sent again.
- `MeetingStore.editTranscriptSegment(_:text:meeting:)` and
  `deleteTranscriptSegment(_:meeting:)` change one line by id and leave its
  speaker, its times and every other line alone. They save through
  `save(transcript:id:)`, so the change posts `.gtMeetingsDidChange` and goes
  up to iCloud like a renamed speaker; a copy fetched from before the edit
  does not replace it (`applyFromCloud` keeps the change made here).
  `synced(id:)` reads the transcript as stored.
- Mac: the transcript column's right-click menu has Edit and Delete…
  (`RichTextView` gained a hook for menu items above the text view's own).
  Edit opens a field above the transcript; Delete… asks first, as deleting a
  meeting does. Both are missing while the meeting is busy.
- iPhone: a long press on a transcript line offers Edit (a sheet,
  `TranscriptLineEditor.swift`) and Delete, which deletes at once as a swipe
  deletes a note.
- The notes are not written again; Redo notes reads the edited transcript.
  Agent access, Export, the chat and the views read the stored text, so they
  show the edit.
- Not taken from Hex: its Labs flag, multi-line selection mode, and clearing
  the notes and title after an edit. No Hex code was adapted.
- Docs: `docs/MEETINGS.md` (Editing the transcript, the window table, sync),
  `docs/IOS.md`.

## Verification

`VoiceIQCore/Tests/VoiceIQCoreTests/MeetingTranscriptEditTests.swift` covers
ids staying stable through edits and deletes, untouched lines, reading back
after a reload, repeated lines, an older iCloud copy not undoing an edit, and
agent access returning the edited words.

Status: pending Mac build. Written in a Linux orb; neither the package tests
nor the macOS and iOS apps have been compiled yet.
