# Coding agent access: local API and MCP server

## What and why

Requested 2026-11-22 by the product owner after seeing FluidVoice's FluidMeet
integrations, which let Claude Code and Codex read meeting transcripts. VoiceiQ
now does the same for both dictation history and meetings, on the Mac, as an
MCP server plus a small read-only JSON API, served by the running app on
127.0.0.1:47823. Off by default (Settings › Advanced › Coding agents).

FluidVoice (GPL-3.0) was read for its design only: an off-by-default loopback
API with a Host and Origin check, and a read-only meeting reader for agents.
No code was copied. Differences: VoiceiQ speaks MCP so agents connect with one
command and need no skill file or bundled helper binary, every request needs a
random access key (FluidVoice's local API has none), and dictations are served
as well as meetings.

## Decisions

- One in-app server (Network.framework, no new dependency) instead of a bundled
  stdio helper. It reads through the app's own `HistoryStore` and
  `MeetingStore`, so it never depends on their file formats, and adds no
  target to sign and notarize. The cost is that the app must be running,
  which it is for a menu bar app.
- Three MCP tools (`list_dictations`, `list_meetings`, `get_meeting`). Meeting
  search lives in `list_meetings` with matching transcript lines.
  `get_meeting` returns the app's own Markdown export by default, which repeats
  no field names per turn; `format: json` gives start and end seconds.
- The key is in the Keychain and read once per launch. A port still held by
  the copy of the app being replaced (update, relaunch) is retried every 2 s
  for 30 s.
- iPhone: no server (iOS cannot keep one running and agents do not run there).
  iPhone dictations and meetings reach agents through iCloud sync to the Mac.

## Verification

- `swift test --package-path VoiceIQCore`: 159 tests pass, including 5 new
  `AgentAPITests`. Removing the Origin check makes them fail.
- Debug build on a macOS 27 satellite with seeded history and meetings:
  `claude mcp add` from the Claude Code button, then `claude mcp list` showed
  `✔ Connected`. MCP Inspector CLI listed the tools and called each one,
  including a search that returned `[01:04] Priya Raman: ...`. Codex 0.171
  parsed the copied config (`codex mcp list`: Bearer token).
- Live checks: no key and a wrong key 401, Origin 403, foreign Host 403,
  DELETE 405, the LAN address refused, the switch off closes the port and on
  reopens it, and New Key turns the old key into 401.
- Not tested on a signed, notarized build: the Mac mini runner was down and
  the brief allowed a Debug build.

## Automatic setup for Claude Code, Codex and Amp (same day)

Asked by the product owner: set the three agents up without copy and paste,
in each one's real user config, and add Amp. `AgentClient` edits
`~/.claude.json` (`mcpServers`), `~/.codex/config.toml` (`[mcp_servers.voiceiq]`)
and `~/.config/amp/settings.json` (`amp.mcpServers`), the locations their docs
and CLIs use (`claude mcp add --scope user`, `codex mcp add`, `amp mcp add`
wrote to exactly these files on the test Mac). The server's queue runs every
sync, so two writes to one file never overlap. Other tools keep the copied
JSON.

- Codex's TOML is edited as text, table by table, rather than through a TOML
  library: VoiceiQ owns whole tables (`[mcp_servers.voiceiq]` and its
  sub-tables), so it never needs to understand the rest of the file, and
  comments elsewhere survive.
- JSON files are rewritten through `JSONSerialization`, which keeps every key
  and value but not the original key order or spacing. Amp settings with
  comments are left alone for that reason.
- VoiceiQ never creates `~/.claude.json`, since Claude Code keeps its whole
  state there.

Verified on a macOS 27 satellite with Claude Code 2.1.330, Codex 0.171 and the
Amp CLI (2026-11-22 build), each with another MCP server already configured:
the app set all three up at launch; `claude mcp list` showed voiceiq
Connected, `codex mcp list` and `amp mcp list` listed it with its URL. Remove
on Amp took it out and it stayed out after a relaunch; New Key rewrote Claude
Code and Codex and the old key got 401; Update fixed a stale Codex key; the
switch off left all three files equal to their state before setup (JSON
compared as values, TOML byte for byte), and on put the entries back. Codex
and Amp's own connection checks need a signed-in account, which the test Mac
did not have.
