# Agents read part of a meeting (2026-11-27)

## Why

Hex added `hex meetings show --from/--to` (`src/meeting/query.rs`, `OffsetRange`, at `f1c772c9`) so an agent can read only part of a long meeting. VoiceiQ's `get_meeting` returned the whole transcript, about 10,000 words an hour, which fills an agent's context on a long call.

## What changed

- `get_meeting` (MCP) and `GET /v1/meetings/<id>` take optional `from` and `to`, times into the meeting as `mm:ss` or `h:mm:ss`, as the transcript shows them. The transcript keeps only turns that overlap the range, whole; the Markdown says which range it shows and the JSON carries `range`. Notes, folders and questions are unchanged. A bad time, or a `from` not before `to`, is an error naming the forms (`isError`, HTTP 400).
- Parsing and filtering are pure (`TranscriptRange`); `MeetingStore.markdown` takes an optional range.
- The tool description, server instructions and `AgentAPI.meetingPrompt` tell agents to read the notes first and then only the part they need.

## Verification

New `AgentAPITests.testGetMeetingReadsOnlyTheTurnsInATimeRange`. Pending Mac build: written in a Linux orb without a Swift toolchain.
