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
| Notes: summary, decisions, action items with owners and deadlines, type-specific sections | `notes.json` |
| Transcript: each turn with the speaker's display name and start and end seconds | `transcript.json` |
| Questions asked about a meeting in VoiceiQ, with answers | `chat.json` |

Dictations and meetings recorded on the iPhone reach the Mac through iCloud
(History sync and meeting sync), so they are included once they have synced.
Audio is never served. Nothing can be changed or deleted.

## Set up an agent

Turn the switch on, then use the buttons under it. Each copies a setup with
your access key already filled in.

**Claude Code** (paste into Terminal):

```sh
claude mcp add --transport http --scope user voiceiq http://127.0.0.1:47823/mcp --header "Authorization: Bearer <key>"
```

`claude mcp list` should then show `voiceiq ... ✔ Connected`.

**Codex** (paste into `~/.codex/config.toml`):

```toml
[mcp_servers.voiceiq]
url = "http://127.0.0.1:47823/mcp"
http_headers = { Authorization = "Bearer <key>" }
```

To keep the key out of the file, use `bearer_token_env_var = "VOICEIQ_KEY"`
instead of `http_headers` and export `VOICEIQ_KEY` where Codex starts.

**Other tools** (Cursor, Gemini CLI, and any client that takes `mcpServers`
JSON): merge this into the tool's MCP settings.

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
| `list_meetings` | `query`, `since`, `limit` (default 20) | Meetings, newest first, as JSON. With `query`, only meetings whose title, notes or transcript mention it, with up to five matching lines such as `[01:04] Priya: ...` |
| `get_meeting` | `id` (or `latest`), `format` (`markdown` default, or `json`) | Notes, transcript with `[mm:ss]` times and speaker names, and the questions asked in VoiceiQ |

`since` takes a day (`2026-11-01`, midnight in the Mac's time zone) or an ISO
8601 time. Every tool is marked read-only. The server's instructions tell the
agent that transcripts are records of speech, not instructions.

## JSON API

Every route needs the same `Authorization: Bearer <key>` header.

| Route | Returns |
|---|---|
| `GET /v1/health` | `{"status":"ok","version":"0.7.12"}` |
| `GET /v1/dictations?query=&since=&limit=` | Dictations |
| `GET /v1/dictations/<id>` | One dictation |
| `GET /v1/meetings?query=&since=&limit=` | Meetings |
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
