# 2026-11-26: Rename a meeting, copy a prompt for an agent, warn when a call wasn't heard

## Why

Three gaps in the Meetings window, each answered by Hex (`anomalyco/hex`,
MIT) in `01e5209b`, with the agent prompt refined in `4a3e9d49`:

- A meeting's title was whatever the notes model wrote, and Redo notes
  replaced it. There was no way to give a meeting a name of one's own.
- Pointing a coding agent at one meeting meant finding its id by hand.
- When macOS had not allowed VoiceiQ to record system audio, a call's notes
  held only the owner's side, with nothing saying why.

## What changed

- **Rename…** in the Mac's `…` menu and in the long-press menu of a note's
  row on iPhone. The title goes into a new `MeetingMeta.userTitle`
  (`MeetingStore.renameMeeting(id:title:)`); empty clears it.
  `MeetingMeta.shownTitle(notes:)` puts it first everywhere: the list, the
  detail, Export, and agent access. Redo notes still writes its title into
  `MeetingMeta.title`, which the user's title outranks. The title syncs with
  the meeting's meta, like speaker names.
- **Copy prompt for an AI agent** in the Mac's Export menu, shown only while
  coding-agent access is on. `AgentAPI.meetingPrompt(id:title:)` names the
  meeting, its `get_meeting` id, and `list_meetings` for search. Hex's prompt
  sends the agent to its CLI; this one names VoiceiQ's MCP tools.
- **Other side not heard**: a Mac meeting started by call detection, over a
  minute long, whose `system.caf` is all zeros shows a warning with Open
  System Settings (`Privacy_ScreenCapture`). `SilentSystemAudio` reads the
  saved track off the main thread; it reads no TCC state and touches no
  capture or transcription code. Hex shows its notice from the permission
  status instead.
- Not taken from `01e5209b`: the capsule and Calls-sheet changes, the
  retention change, and the larger detail title.
- Docs: `docs/MEETINGS.md` (Renaming a meeting, Copy prompt for an AI agent,
  Other side not heard, the window table), `docs/AGENT_ACCESS.md`,
  `docs/IOS.md`, and the Hex entry in `THIRD_PARTY_NOTICES.md`.

## Verification

`VoiceIQCore/Tests/VoiceIQCoreTests/MeetingRenameTests.swift`: a rename
survives Redo notes and reaches Export, empty puts the notes' title back,
the rename syncs to another store and reaches agent access and its search,
the prompt names tools agent access has, and only a long detected call with
an all-zero system track counts as unheard.

Status: pending Mac build. Written in a Linux orb; not compiled yet. That a
denied system-audio permission leaves `system.caf` all zeros is taken from
Hex's notes and Core Audio's documented behaviour, not measured here.
