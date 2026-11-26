# 2026-11-26 Hex and FluidVoice port: what came in and what didn't

Reviewed Hex `db515bda..012bdbbe` (MIT) and FluidVoice `87fbef8b..ffa6639e`
(GPL-3.0, clean-room only). cyron asked for everything that fits VoiceiQ,
then gave the watch full autonomy to decide. The guardrail was to keep
VoiceiQ's own design, wording, settings and flows, and to skip anything that
would reshape it.

## Built

| PR | What |
|----|------|
| #75 | Paste on macOS 27.3 needs the posting grant (System & App Protection Override). VoiceiQ asks for it, offers a restart, and refuses before touching the clipboard. Hex `341046f8`, `0744db0d`. |
| #76 | The iPhone shows recording only once audio flows (Hex `a2d940e3`). Downloading a model over cellular asks once, with the model's size (cyron's rule instead of Hex `9e41970e`'s Wi-Fi-only design). |
| #77 | The pill re-homes when stranded on another Space (`8c9489b6`). Cancelling a take over 10 s needs a second ⌘Esc (`9d6e0990`). Adds an optional middle-mouse trigger (`dc0e6e7c`), Add to Dictionary… in the menu bar (`9e9ce59f`), and clearer dictionary labels (`dea95c0f`, FluidVoice `6e0c0b4e`). |
| #78 | The system-audio tap rebuilds on an output switch or a dead tap (`5704885d`, `4a3e9d49`). An output-only device is never used as the call mic (`657aa0cf`). Browser calls end on lock (`092a9b33`). Aside is detected as a call browser (`ae1cdf71`). Adds Mute my mic (`6118eb82`) and Discard while recording (`01e5209b`). "Keep recording" no longer truncates (FluidVoice `7c744b79`). |
| #79 | Edit or delete transcript lines (`e67eec00`, FluidVoice `c81c83cd`). Rename a meeting and Copy prompt for an AI agent (`01e5209b`, `4a3e9d49`). Warns when a call's system track is silent (adapted from `01e5209b`, with no private TCC API). |

## Decided against

- **Spoken "my clipboard" phrase** (Hex `be3ead04`). On by default it would
  replace ordinary sentences such as "I copied it to my clipboard". Hex keeps
  it off in Labs. VoiceiQ has no Labs, and a new setting for a niche phrase
  doesn't earn its place.
- **Shortcut to switch transcription source** (`7a2c78ac`). Every action in
  `ShortcutStore` has a default key and there is no unassigned state, so this
  needs a store and recorder rework for a rarely used toggle.
- **Pick one app or output device for a manual recording** (`7364c058`). It
  changes the one-button start flow.
- **Hold Paste Last to pick from recent dictations** (`339a1895`, `aeb1251c`,
  `91a2cc5d`). Adds a new floating picker and a second behaviour to an
  existing shortcut. History already covers older dictations.
- **"Meeting ready" card after a meeting** (`01e5209b`, `d00c79ef`). A new HUD
  stage in the core meeting flow.
- **What's new sheet** (Hex `1bbac977`) and **recent meetings on a home
  screen** (FluidVoice `c7d0bfba`). These would add a new flow or a new main
  screen.
- **Auto-stop a manual recording when its call ends** (`e5f6dac8`). VoiceiQ
  already does this.
- **Pill on the mouse's screen** (`59448fd4`). VoiceiQ already does this.
- **Offline rule-based cleanup**: owned by the "Drop on-device writer, add
  rule cleanup" thread. **iOS keyboard**: owned by the "Hex QWERTY keyboard
  for iPhone" thread.
- About 180 Android, Windows, Linux, site, annotate, Rust refactor and Hex-only
  commits are out of scope.

## Calls made

- **Cellular download confirmation is once per download, not once ever.**
  Each model is hundreds of MB, and a later download may happen on a
  different plan or roaming. Remembering a single yes would silently spend
  data months later.
- **The posting-grant restart is offered, never automatic.** VoiceiQ cannot
  loop, so Hex's one-restart marker isn't needed.
- **Mac builds and tests ran on an Amp Mac satellite**, not on the
  lobsters-mac-mini runner, because this work was not allowed to start
  another thread.

Baselines after this review: Hex `012bdbbe`, FluidVoice `ffa6639e`.
