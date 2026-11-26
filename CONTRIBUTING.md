# Contributing to VoiceiQ

Bug reports, fixes, and features are welcome through GitHub issues and pull
requests. Open an issue first for anything larger than a focused fix, so the
approach can be agreed before the code is written.

## Getting started

```bash
brew install xcodegen
./scripts/test.sh          # VoiceIQCore tests, fast and headless
./scripts/build.sh         # macOS app, Debug
./scripts/build-ios.sh     # iPhone app, keyboard and Live Activity (Simulator)
```

The repository builds two apps from one generated project (`project.yml`):
the macOS menu bar app in `App/` and the iPhone app in `iOS/`, with its voice
keyboard and Live Activity extensions. Both use the `VoiceIQCore` package.

`docs/design/architecture.md` explains how the pieces fit, and `docs/IOS.md`
covers the iPhone app, keyboard and background session. `docs/RELEASING.md`
covers signing, notarization and TestFlight; contributors need none of that
for a Debug build, and Debug builds sign ad-hoc.

## Pull requests

Every submission is reviewed through a GitHub pull request. Keep a PR to one
change. Describe what changed, why, and how you verified it. Update `docs/`
when behavior, setup, or architecture changes.

A change to `VoiceIQCore` affects both apps. Run `./scripts/test.sh`,
`./scripts/build.sh` and `./scripts/build-ios.sh` before opening the PR; CI
runs all three. Say in the PR which platform you checked by hand (a Mac, the
iOS Simulator, or an iPhone).

By opening a pull request you confirm that you wrote the code, or otherwise have
the right to contribute it under this repository's license.

## Ground rules

1. **Swift, Apple platforms, Gemini models.** macOS and iOS, native
   frameworks only. Gemini models only, reached on Google's Gemini API with
   the user's own key (see `docs/design/architecture.md`). No on-device
   speech models, no other model families, no gateways, no cross-platform
   layers.
2. **Share code through `VoiceIQCore`.** Logic both apps need goes in the
   package, not in `App/` or `iOS/`. Mac-only code is wrapped in
   `#if os(macOS)`; its iPhone stand-in lives in a sibling file ending
   `+iOS.swift`. The keyboard and Live Activity extensions link only
   `VoiceIQBridge`, which must stay extension-safe: no networking, no audio,
   and nothing that `APPLICATION_EXTENSION_API_ONLY` rejects.
3. **The keyboard stays a remote control.** It sends commands through the App
   Group and inserts text; recording, keys and model calls stay in the app.
   Keyboard extensions have a tight memory limit and no network by default.
4. **It has to just work by default.** New behavior ships with a sensible default
   and no required setup. Add a setting only when users genuinely need to choose.
5. **Cleanroom policy.** GPL-licensed projects in this space may be studied for
   behavior, never copied. Do not port, translate, or paraphrase their code into
   this repository.
6. **No secrets, ever.** No API keys, tokens, or signing material in code,
   fixtures, tests, or CI files. The app takes the user's own keys at runtime and
   stores them in the Keychain (macOS and iOS). Signing keys, provisioning
   profiles and App Store Connect API keys stay on the release Mac.
7. **Design tokens only.** Mac UI changes use `DesignTokens.swift` and
   `MotionTokens.swift`. If a value is not in the tokens file, add it there
   first. The full design contract is `docs/design/experience.md`. iPhone UI
   uses standard SwiftUI controls and the `Brand` colors in
   `iOS/App/Sources/VoiceIQMobileApp.swift`.
8. **Prompt changes need evidence in the PR.** `PromptV1.swift` is the
   dictation prompt: one call hears the recording and writes the text. Run
   the eval set in `eval/SCORECARD.md` on main and on your branch and put both
   scores in the PR. It covers a self-correction, a spoken list,
   question-shaped speech, spoken punctuation, an all-filler take, a spoken
   instruction that must be written down rather than obeyed, names and
   latency with screen context on.
9. **Never-lose-words is an invariant.** Any change touching audio, networking,
   or insertion must keep these true on both platforms: audio is on disk before
   network I/O begins; every failure writes a terminal status; errors are never
   modal; nothing is silently discarded.
10. **No telemetry.** PRs adding analytics, tracking, or phone-home behavior will
   be declined. The only model service is the Gemini API, with the user's
   key.
11. **Keep files small.** Around 500 lines per source file; split when it improves
   clarity, not to hit a number.
