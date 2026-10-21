# 2026-10-21: Dictation key speaks to the open agent panel

## Why

With the agent panel open, pressing the dictation key (fn by default)
showed Listening and Transcribing in the panel, then inserted the text into
the app behind it. The panel never takes focus, so the dictation went to the
frontmost app as usual. The only ways to send a command were the Agent
shortcut or the panel's mic button.

## What changed

- `DictationController.start()`: when the hotkey grammar emits `.begin`
  and `agent.isOpen`, the press calls `startAgentListening()` instead of
  the coordinator's insert path. The next press ends the command the usual
  way. If the agent has no model or is still working, the press is ignored
  and the grammar is reset so it does not arm a phantom session.
- Review fix (PR #12, CodeRabbit): the agent route applies only when the
  coordinator is idle or terminal. A hands-free dictation started from the
  menu item or `voiceiq://start-hands-free` while the panel is open keeps
  the dictation key as its stop through the refused-begin path. Verified on
  the notarized build: panel open, URL start, speech, ⌃⌥D → "begin ignored:
  session already active", finalize, cleanup, insert; panel open and idle,
  ⌃⌥D → "dictation key speaks to the agent".
- `startAgentListening()` now reports whether it began, so the key path
  can reset the grammar when it did not.
- `transition(to:)` resets the hotkey grammar on every terminal coordinator
  state. A session the key started can end from the Agent shortcut or the
  panel's Done button; before this the grammar stayed in `.locked` and
  swallowed the next press as a stop. When the grammar ended the session
  itself it is already idle, so the reset is a no-op there.
- Agent panel idle line names both keys: "Press the Agent shortcut or fn
  and speak".
- `docs/AGENT-MODE.md` describes the routing.

## Verification

Notarized 0.6.2 build from `scripts/release.sh` (`SKIP_TESTS=1`; the
VoiceIQCore tests were skipped because another agent's local-model work was
uncommitted in the tree and the change is App-only), installed to
`/Applications`. Keys were posted with `cua-driver`, which cannot send a
bare fn, so the dictation trigger was set to ⌃⌥D for the run and deleted
afterwards. Speech was played into the Jump Desktop loopback microphone.

- Panel closed, ⌃⌥D twice: "Baseline dictation into TextEdit." inserted
  into TextEdit via AX.
- Panel open (⌃⌥G, ⌃⌥G), ⌃⌥D, speech, ⌃⌥D: log shows "dictation key
  speaks to the agent", usage `agent/transcribe`, no insertion. The panel
  shows the command "What is two plus two? Answer with one word." TextEdit
  kept only its marker line. The agent reply failed with 401 "Missing API
  key" from the model host; that is server configuration, not this change.
- ⌃⌥D to start, ⌃⌥G to end, ⌃⌥D again: the second ⌃⌥D started a new
  session (grammar reset works).
- Stop in the panel, then ⌃⌥D twice: text inserted into TextEdit again.

Gap: fn itself was not pressed by the harness; the fn trigger shares the
same `HotkeyProcessor` grammar and intent loop as the combo.

## Rollback

Revert the four edited files. No settings or data formats changed.
