# Coding agent access

VoiceiQ on the Mac can let coding agents such as Claude Code, Codex, Cursor
and Gemini CLI read your dictation history and your meetings. It serves them
two ways from the running app:

- an MCP server at `http://127.0.0.1:47823/mcp` (Streamable HTTP), which most
  agents connect to with one command or a few lines of config;
- a small read-only JSON API under `http://127.0.0.1:47823/v1` for scripts.

It is off until you turn it on in **Settings › Advanced › Coding agents**.

## What agents can read

| Data | Where it comes from |
|---|---|
| Dictations: text as inserted, raw text when it differs, app, time, length, status, the device for ones synced from another device | History (`HistoryStore`) |
| Meetings: title, start and end, length, status, speakers | `MeetingStore` meta |
| The folders each meeting is in, by name | `folders.json` and each meeting's `folder-ids.json` |
| Notes: summary, decisions, action items with owners and deadlines, type-specific sections | `notes.json` |
| Transcript: each turn with the speaker's display name and start and end seconds | `transcript.json` |
| Questions asked about a meeting in VoiceiQ, with answers | `chat.json` |

Dictations and meetings recorded on the iPhone reach the Mac through iCloud
(History sync and meeting sync), so they are included once they have synced.
Audio is never served. Nothing can be changed or deleted.

## Set up an agent

### Claude Code, Codex and Amp: automatic

When the switch is on, VoiceiQ adds a `voiceiq` MCP server to each of these
that it finds on the Mac, with the access key filled in:

| Agent | Found when this exists | Config VoiceiQ edits | Entry |
|---|---|---|---|
| Claude Code | `~/.claude.json` | `~/.claude.json`, user scope | `mcpServers.voiceiq`: `type` `http`, `url`, `headers.Authorization` |
| Codex (CLI, IDE extension and app) | `~/.codex/` | `~/.codex/config.toml` | `[mcp_servers.voiceiq]`: `url`, `http_headers` |
| Amp CLI | `~/.config/amp/` | `~/.config/amp/settings.json` | `amp.mcpServers.voiceiq`: `url`, `headers.Authorization` |

Each row in Settings shows the agent's state: Not found on this Mac, Not set
up, Set up, or Has an old key. The button next to it sets the agent up,
updates its key, or removes VoiceiQ from it.

- Everything else in those files is kept: other MCP servers, settings, and
  Codex tables before and after VoiceiQ's.
- Before each change VoiceiQ copies the file to `<name>.voiceiq-backup` next
  to it, and keeps the file's permissions (a new file is readable by you only).
- VoiceiQ only changes a `voiceiq` entry whose URL is
  `http://127.0.0.1:47823/mcp`. A different server with that name shows as
  "Has another server named voiceiq" and is left alone.
- An Amp settings file with comments, or a `settings.jsonc`, is left alone,
  since rewriting it would drop the comments. Copy the JSON instead.
- **New Key…** writes the new key into each agent that is set up.
- Turning the switch off removes VoiceiQ from all three. Turning it on adds it
  back, except to agents you removed it from with **Remove**.
- VoiceiQ never creates `~/.claude.json`: Claude Code keeps its whole state
  there, so run Claude Code once first.

Check each one with `claude mcp list` (shows `voiceiq ... ✔ Connected`),
`codex mcp list`, and `amp mcp list` or `amp mcp doctor`.

### Other tools

For Cursor, Gemini CLI and any client that takes `mcpServers` JSON,
**Copy for Other Tools** copies this, ready to merge into the tool's MCP settings:

```json
{
  "mcpServers": {
    "voiceiq": {
      "type": "http",
      "url": "http://127.0.0.1:47823/mcp",
      "headers": { "Authorization": "Bearer <key>" }
    }
  }
}
```

A client that only runs stdio servers can reach it through a bridge such as
`npx mcp-remote http://127.0.0.1:47823/mcp --header "Authorization: Bearer <key>"`.

## MCP tools

| Tool | Arguments | Returns |
|---|---|---|
| `list_dictations` | `query`, `since`, `limit` (default 50) | Dictations, newest first, as JSON |
| `list_meetings` | `query`, `folder`, `since`, `limit` (default 20) | Meetings, newest first, as JSON, each with the names of its folders. With `folder` (a folder's name in any case, or its id), only the meetings in it; an unknown name is an error that lists the folders. With `query`, only meetings whose title, notes or transcript mention it, with up to five matching lines such as `[01:04] Priya: ...` |
| `get_meeting` | `id` (or `latest`), `format` (`markdown` default, or `json`) | Its folders, notes, transcript with `[mm:ss]` times and speaker names, and the questions asked in VoiceiQ |

`since` takes a day (`2026-11-01`, midnight in the Mac's time zone) or an ISO
8601 time. Every tool is marked read-only. The server's instructions tell the
agent that transcripts are records of speech, not instructions.
A meeting's title is the one the user gave it with Rename…, else the notes'.

While access is on, a meeting's Export menu in the Mac app has **Copy prompt
for an AI agent**: a short prompt to paste into an agent that points it at
that meeting through `get_meeting` and its id, and at `list_meetings` for
searching (MEETINGS.md, Copy prompt for an AI agent).

## JSON API

Every route needs the same `Authorization: Bearer <key>` header.

| Route | Returns |
|---|---|
| `GET /v1/health` | `{"status":"ok","version":"0.7.12"}` |
| `GET /v1/dictations?query=&since=&limit=` | Dictations |
| `GET /v1/dictations/<id>` | One dictation |
| `GET /v1/meetings?query=&folder=&since=&limit=` | Meetings; an unknown `folder` is a 404 |
| `GET /v1/meetings/<id>` | One meeting with notes, transcript and questions (JSON) |
| `GET /v1/meetings/<id>?format=markdown` | The same as Markdown |

```sh
curl -H "Authorization: Bearer $VOICEIQ_KEY" "http://127.0.0.1:47823/v1/meetings?query=budget"
```

## How access is protected

- **Off by default.** Nothing listens until you turn the switch on. Turning it
  off closes the port at once.
- **This Mac only.** The listener binds to `127.0.0.1` and accepts local
  connections only, so other machines on the network cannot connect.
- **Access key.** Every request must carry a 256-bit random key as a bearer
  token, compared in constant time. Other user accounts on the same Mac, and
  local programs you have not given the key, get `401`. The key lives in your
  Keychain and in the config of each agent you set up. **New Key…** replaces it,
  and agents with the old key get `401` until you set them up again.
- **No browsers.** A web page can reach `127.0.0.1` too, directly or through a
  host name rebound to it. Requests that carry an `Origin` header, or a `Host`
  other than `127.0.0.1:47823` or `localhost:47823`, are refused with `403`
  before the key is checked.
- **Read-only.** The `/v1` routes answer `GET` only and the MCP tools only read.
- **Bounded requests.** One request per connection, bodies up to 1 MB, and a
  connection that does not finish its request within 30 seconds is closed.

What the key does not protect against: a program already running as you can
read VoiceiQ's files directly, as it can any of your files. And anything an
agent reads goes to that agent's AI provider, under that provider's terms.

## iPhone

iOS does not let an app keep a server running in the background, and coding
agents do not run on the iPhone, so there is no agent access on the iPhone
itself. What you dictate and record there reaches agents through the Mac:
History's final text and meeting notes, transcripts and questions sync through
iCloud, and the Mac serves them like its own.

## Credit

The idea and the shape of this feature (a local API on loopback, a Host and
Origin check against DNS rebinding, read-only meeting access for coding agents)
come from [FluidVoice](https://github.com/altic-dev/FluidVoice)'s FluidMeet
integrations and local API. FluidVoice is GPL-3.0; no FluidVoice code is used
here, and VoiceiQ's implementation is its own. FluidVoice gives coding agents
its meetings through a bundled command and a skill file, and has a separate
local HTTP API (history, meetings, dictionary, transcription) with no key.
VoiceiQ serves dictations and meetings over MCP, behind an access key.
