# Agents read part of a meeting; meetings saved as Markdown (2026-11-27)

## Why

Hex added `hex meetings show --from/--to` (`src/meeting/query.rs`, `OffsetRange`, at `f1c772c9`) so an agent can read only part of a long meeting. VoiceiQ's `get_meeting` returned the whole transcript, about 10,000 words an hour, which fills an agent's context on a long call.

## What changed

- `get_meeting` (MCP) and `GET /v1/meetings/<id>` take optional `from` and `to`, times into the meeting as `mm:ss` or `h:mm:ss`, as the transcript shows them. The transcript keeps only turns that overlap the range, whole; the Markdown says which range it shows and the JSON carries `range`. Notes, folders and questions are unchanged. A bad time, or a `from` not before `to`, is an error naming the forms (`isError`, HTTP 400).
- Parsing and filtering are pure (`TranscriptRange`); `MeetingStore.markdown` takes an optional range.
- The tool description, server instructions and `AgentAPI.meetingPrompt` tell agents to read the notes first and then only the part they need.

## Save each meeting as Markdown (Mac)

Hex saves each meeting's notes as Markdown in a folder the user picks and rewrites the file only while it still matches the hash of what Hex last wrote (`src/meeting/notes_file.rs`, `src/meeting/write/markdown.rs`, `ee9b069a`). VoiceiQ had only a manual Export to Downloads.

- Settings › Dictation, the meetings rows: **Save each meeting as Markdown**, off by default; turning it on asks for a folder. Not sandboxed, so the folder is a path.
- `MeetingMarkdownFiles` writes `<title> <yyyy-MM-dd>.md` with Export's Markdown (notes above the transcript) once a meeting is done with notes, and rewrites it after redo, rename or a transcript edit only while it still has the SHA-256 VoiceiQ stored for that meeting. A taken name gets " 2", " 3". It follows `MeetingStore`'s change notification on a background queue, so `MeetingEngine` is not edited and a failure is only logged.

## Verification

New `AgentAPITests.testGetMeetingReadsOnlyTheTurnsInATimeRange` and `MeetingMarkdownFilesTests`. Pending Mac build: written in a Linux orb without a Swift toolchain.
