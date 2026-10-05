# Agent mode

A fourth mode. The user presses the Agent shortcut, speaks a
command, and one model looks at the screen, acts through macOS Accessibility
and CGEvent, and reports in the pill panel. The session stays open, with its
transcript, until Stop. Research and the decisions behind this design are in
`design/agent-mode-research.md`.

## Turning it on

Settings → Dictation → **Agent mode**. The shortcut row
(`ShortcutAction.agent`, default ⌃⌥G) appears under the toggle; it is not in
the Shortcuts list. The toggle persists as `agentModeEnabled`.

The agent needs Accessibility and Screen Recording for VoiceiQ. Without them
every observation returns a limitation line instead of a screenshot and the
model says what is missing.

## Session flow

```diagram
┌──────────────┐ shortcut ┌──────────────────┐ transcript ┌───────────────┐
│ Dictation    │─────────▶│ Recording session│───────────▶│ AgentController│
│ Controller   │          │ (mode: .agent)   │            │   .submit     │
└──────────────┘          └──────────────────┘            └───────┬───────┘
                                                                  │
                     ┌────────────────────────────────────────────▼──────┐
                     │ AgentLoop.handle(command)                          │
                     │  1. executor.observe()  → screenshot + AX summary  │
                     │  2. transport.send(conversation)                   │
                     │  3. tool calls → executor.perform(...) → results   │
                     │  repeat 2–3 until answer/done, ≤ 25 steps          │
                     └────────────────────────────────────────────────────┘
```

- First shortcut press opens the panel and listens. While listening a press
  ends the command. While idle a press listens again. Only the panel's Stop
  button closes it; click-away and Esc do nothing.
- The panel is the pill (`PillState.agent`) at the Ask Anything answer size
  (560×300 max). `AgentPanelView` renders the transcript: commands, observation
  lines, actions with status, confirmations, answers, failures.
- Answers are Markdown. `App/Sources/DesignSystem/MarkdownView` lays them out
  block by block: paragraphs, headings, numbered and bulleted lists,
  code in a box, quotes, and GFM tables. A list item and a quote each hold
  their own block sequence, so nested lists, code blocks and tables inside
  them keep their formatting. `MarkdownBlocks.swift` groups the
  `AttributedString(markdown:)` presentation intents into those blocks. The
  Ask Anything answer (`App/HUD/AnswerView`) and the saved-run detail in
  `AgentRunsPane` (which draws `AgentEntryRow`) use the same view.
- Tables (`MarkdownTableView.swift`) size columns like HTML auto layout. Each
  column has a minimum (its longest word) and a preferred width (its longest
  line, capped at 320 pt). If the preferred widths fit the panel the table
  fills it. If not, the widest column wraps first, down to its minimum, then
  the next. If even the minimums do not fit, columns keep their preferred
  widths and the table scrolls sideways inside its own frame; the rest of the
  transcript does not move.
- Pill states a dictation session would show (listening, processing, error)
  become the panel's phase line (`DictationController.reflectInAgentPanel`).
- Stop cancels any running turn, closes the panel, and returns the pill to
  its resting state. The transcript stays in the Agent section (below).
- The panel never takes focus. `PillHUDController` is a non-activating
  panel; if a click on its buttons still activates VoiceiQ (seen on the
  MacBook), `DictationController.handBackActivation` activates the app that
  was frontmost before, so the next command acts on the right window. It
  skips the hand-back when a regular VoiceiQ window (Settings, onboarding)
  is visible.
- After each action `NativeExecutor` waits before the next observation so
  the target app can react: 800 ms for click, click_at, press and
  invoke_menu; 300 ms for type; 400 ms for scroll; 1 s for open_app.

### Agent runs are not History

`DictationMode.keepsRecording` is false for `.agent`, so
`DictationCoordinator.discardUnlessKept()` drops the recording and transcript
once the command is handed to the agent (and on failure or cancel). Nothing
from the agent lands in `history.sqlite` or the History pane.

Instead `DictationController` saves the session through `AgentRunStore`
whenever the transcript changes (`AgentController.onSessionChange`) and the
session has at least one command. One JSON file per session lives at
`~/Library/Application Support/VoiceiQ/agent-runs/<uuid>.json`
(`FileLayout.agentRunsRoot`), rewritten whole; runs hold text only, no
screenshots. The main window's **Agent** section (`MainSection.agent`,
`App/Sources/Windows/AgentRunsPane.swift`) lists runs newest first and shows
one run's full transcript with Copy, Delete and Delete All. History's
"Delete all" does not touch agent runs; the Agent pane owns them.

Every command starts with an observation, so "explain what I am looking at"
and "explain a quadratic equation" both see the screen before the model
decides whether to answer from it, act, or answer generally.

### How a command ends

There is no confidence score. The loop sends the conversation, runs every
tool call the model makes, observes again, and sends again, until the model
replies with no tool calls or calls `answer` or `done`. The hard cap is
`AgentLoop.maxSteps` (25) per command; past it the transcript says
"Stopped after 25 steps". Prompt rule 6 (look things up before asking) is the
only lever pushing the model to gather more before answering.

### Spoken commands are transcribed like Ask Anything

The command is transcribed by the dictation provider and model, not the agent
endpoint (`GeminiTranscriptionService.transcribe` with `context.mode ==
.agent`). The `.agent` mode skips the live stream, the writing-rules cleanup
pass and the second opinion, and `transform` applies only the dictionary's
hard replacements. That is why an agent command comes back faster than a
dictation: fewer passes, not a different model.

### Screenshots on disk

Peekaboo registers the element snapshot an element-id click needs only when
it writes the observation PNG to disk, so `NativeExecutor.capture` lets it
write into `$TMPDIR/VoiceiQ-agent/` and deletes the file as soon as
`observe` returns; the bytes the model sees come from memory. The directory
is removed and recreated in `NativeExecutor.init`, so a crash mid-observe
leaves at most one file until the next session. Builds before 2026-10-01
left one full-resolution PNG per observation in `$TMPDIR`
(`peekaboo-observation-*.png`); macOS purges that directory on its own
three-day schedule, and the app does not delete those older files.

## Code map

| Layer | Files |
|---|---|
| Model and loop (Core, no AppKit) | `VoiceIQCore/Sources/AgentEngine/`: `AgentLoop`, `AgentConversation`, `AgentTools`, `AgentSession`, `AgentRunStore`, `AgentEndpoint`, `AgentProviderOverride`, `AgentTransport` (+`OpenAI`, `+Anthropic`, `+Gemini`) |
| Screen and actions (App) | `App/Sources/Agent/NativeExecutor.swift` |
| Session and panel (App) | `App/Sources/Agent/AgentController.swift`, `AgentPanelView.swift`, `AgentEntryRow.swift`, `PillState.agent` in `App/Sources/HUD` |
| Answer layout (App) | `App/Sources/DesignSystem/MarkdownBlocks.swift`, `MarkdownView.swift`, `MarkdownTableView.swift` (shared with `App/Sources/HUD/AnswerView.swift` and `AgentRunsPane`) |
| Saved runs (App) | `App/Sources/Windows/AgentRunsPane.swift`, `MainSection.agent` in `SettingsWindow.swift` |
| Settings | `DictationPane` (toggle + shortcut), `App/Sources/Windows/AgentProviderSection.swift` |

`AgentLoop` depends on `ActionExecutor` and `AgentTransport` protocols only;
`NativeExecutor` is the one executor.

## Tools

Function tools on every API format (`AgentTool`):

| Tool | Does |
|---|---|
| `observe` | Screenshot of the frontmost window (main display fallback) as JPEG, longest edge 1280 px, plus the AX element list of that window. |
| `wait` | Sleeps up to 5 s for a page or app to settle, then observes again. |
| `web_search` | TinyFish search: titles, URLs, snippets. Offered only when a TinyFish key is saved (Settings → Advanced); the model is told to look things up before asking the user. |
| `fetch_page` | TinyFish page read as text, for when a snippet is not enough. |
| `click` | AXPress on an element from the last observation, by its number. |
| `click_at` | CGEvent click at a point from the last screenshot. |
| `type` | Types text into the focused element. |
| `press` | Key chord, e.g. `cmd+s`. |
| `scroll` | Scrolls at a point or element. |
| `invoke_menu` | Menu path in the frontmost app, e.g. `File > Save`. |
| `open_app` | Launches or activates an app by name. |
| `answer` | Final text for the user; ends the turn. |
| `done` | Task finished; summary ends the turn. |

Actions whose target text contains a risky word (`NativeExecutor.riskyWords`:
send, pay, delete, submit, log in, …) ask first. The confirmation appears
inline in the transcript: Allow once, Always this session, or Not now.

All AX and CGEvent work goes through Peekaboo's `PeekabooAutomationKit`
(`project.yml`, pinned to revision `31d67ea858bcd9824f9f8cfe5bb105cc4ff53783`;
the package has no tagged releases).

## Model and provider

`AgentEndpoint.resolve()` picks the host once, when the panel opens. A
provider or key saved while the panel is open takes effect after Stop and
the next shortcut press. It resolves to:

1. **Custom provider** (Settings → Advanced → Agent mode provider) when
   enabled, the base URL parses, and a model is selected.
2. Otherwise the dictation route: Gemini uses the formatting model on the
   configured endpoint; OpenAI uses the writing model on `api.openai.com`.

The override (`AgentProviderOverride`, JSON under `agentProviderOverride`;
key in the Keychain as `agent-provider-api-key`) has a base URL, API key,
API format, headers, query parameters, and a list of model IDs with optional
display names, one selected. A model is added from two rows, "New model ID"
and "Display name", and the Add Model button or Return. Every agent request
carries `User-Agent: VoiceiQ/<version> (<build>)` so proxy logs can tell the
app's calls apart; a custom header of the same name replaces it. Formats:

| Format | Path appended to the base URL | Validate call |
|---|---|---|
| OpenAI Chat Completions | `/v1/chat/completions` | `GET /v1/models` |
| OpenAI Responses | `/v1/responses` | `GET /v1/models` |
| Anthropic Messages | `/v1/messages` | `GET /v1/models` |
| Google Generative AI | `/v1beta/models/{id}:generateContent` | `GET /v1beta/models` |

Save & Validate stores the key, then lists models. 401/403 marks the key
invalid; other HTTP errors keep the key and show a note; a network failure
keeps the key as saved offline. A host that lists the selected model gets
"The host lists N models, including yours."

CLIProxyAPI is the primary target: one base URL serves all four formats, and
the Anthropic and Gemini models become reachable through it. Any host that
speaks one of the formats works.

## Context and caching

`AgentConversation` is one append-only message list rendered per format.
Screenshots are the cost driver, so only the last 3 images stay in context;
once a sixth arrives the oldest are replaced by a short placeholder, in
batches, so the cached prefix survives most calls. Bodies are serialized
with sorted keys so the bytes of the prefix never change between calls.

### Policy per model family

`AgentCachePolicy` (`AgentEngine/AgentCachePolicy.swift`) decides what to
send from the model id, not the host, because one CLIProxyAPI URL serves
every vendor. `ModelFamily.infer` strips a `vendor/` prefix and maps
`claude*` → Anthropic, `gemini*`/`gemma*` → Google, `gpt*`/`chatgpt*`/
`o1`/`o3`/`o4` → OpenAI; the Anthropic and Google API formats force their
family.

| Family | Fields sent | Why |
|---|---|---|
| OpenAI (Chat and Responses) | `prompt_cache_key` = one id per session, on every host | Pre-5.6 models route by this key; 5.6+ cache automatically. Hosts that do not know the field answer 400 and the session falls back (below). No `prompt_cache_retention`: 24 h is already the default where supported, and CLIProxyAPI drops it. |
| Anthropic (Messages format, or a `claude*` id on a Chat host) | `cache_control` on the last tool (`ephemeral`, `ttl: "1h"`), on the system prompt (same), and on the last block of the newest message (`ephemeral`, 5 min) | Tools and system never change in a session, so a 1 h entry (2× write) outlives any pause; the moving breakpoint reuses the previous call's prefix. Longer TTL precedes shorter, as Anthropic requires. On a Chat host the system string becomes one text part so it can carry the field. |
| Google | nothing | Implicit caching needs no fields. Explicit `cachedContents` would add storage fees and a cache write per turn for a prefix that changes every call. |
| Other | nothing | Unknown model; plain request. |

Fallback: `AgentTransport.post` sends the body with cache fields; a 400
whose message names one (`prompt_cache`, `cache_control`, `ttl`,
`unknown parameter`, `unrecognized`, …) sets `HostState.cacheFieldsRejected`
and the same request goes out once more without them. Every later call of
the session is plain, so a strict host costs one extra round trip, not one
per step.

Usage: `cached_tokens` from `prompt_tokens_details` / `input_tokens_details`,
`cache_read_input_tokens` from Anthropic, `cachedContentTokenCount` from
Gemini. Every step is metered as `UsageActivity.agent` / stage `agentStep`
and shows in Cost Analysis (see `COST_TRACKING.md`). Anthropic
`cache_creation_input_tokens` and OpenAI `cache_write_tokens` are counted as
plain input, so the shown cost is slightly under the billed cost on cache
writes.

### Measured (2026-10-01, after the policy change)

Harness: `.amp/in/cacheprobe` drives `AgentTransport` with the real system
prompt and tools, three commands, fake 1280×800 screenshots that differ per
step, and prints each host's usage. Cached share is of all input tokens over
the run; the first call of a run can never be cached, and the newest
message never is, so the ceiling for a 6-call run is around 75 %.

| Host, format | Model | Cached | Note |
|---|---|---|---|
| api.openai.com, Chat | gpt-4.1-mini | 70 % (was 56 %) | Every call after the first hit the full previous prefix. |
| CLIProxyAPI, Responses | gpt-6-luna | 70 % (was 50 %) | `prompt_cache_key` accepted by the proxy. |
| CLIProxyAPI, Anthropic Messages | claude-haiku-4-5 | 63 % | Call 2: 8166 in, 5273 cached, i.e. everything before the newest message. |
| CLIProxyAPI, Chat with a Claude id | claude-haiku-4-5 | 54 % (3 calls) | Same per-call hit rate as the Messages format; the proxy accepts `cache_control` inside Chat bodies (HTTP 200). |
| CLIProxyAPI, Gemini | gemini-3.5-flash-lite | 48 % | Implicit cache in 4 096-token blocks; the trailing partial block is never cached, so short prompts cache nothing. |
| CLIProxyAPI, Gemini | gemini-3.8-flash-high | 0 % | The proxy's "antigravity" route only hits on a byte-identical prompt: a 7 000-token system prompt followed by a different one-line user turn missed every time. Not fixable from the client. `gemini-3.1-flash-lite` and `gemini-3.5-flash-lite` on the same proxy hit on prefix. |

Direct Gemini and direct Anthropic keys were not available on the build
machine; the Anthropic numbers are through CLIProxyAPI, which forwards the
cache fields. There is no per-session
token or cost cap; the only bound is 25 steps per command.

## Debug hooks

Debug builds only (`AppDelegate.dispatch`):

- `voiceiq://agent` presses the Agent shortcut.
- `voiceiq://agent/<command>` opens the panel and runs the URL-encoded command
  without the microphone, e.g.
  `open "voiceiq://agent/Explain%20what%20I%20am%20looking%20at"`.
- `voiceiq://settings/agent` opens the Agent runs section (all builds).

`open` activates VoiceiQ as a side effect; use `open -g` when testing the
focus hand-back.

Debug builds are ad-hoc signed, so every rebuild is a new signer to the login
keychain and the first key read prompts; the main thread waits on that prompt.
Re-enter the agent provider key after a rebuild when testing on a machine
without the data-protection keychain entitlement.
