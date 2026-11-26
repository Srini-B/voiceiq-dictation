# Dictation: Dictionary names and latency (2026-11-26)

## Why

Indian names in the Dictionary came out as English look-alikes (Kiran as Karen, Srini as Sreeni), and Gemini dictations with screen context took 5 s at the median and 15–20 s at p90. The writing model stays `gemini-3.8-flash` at thinking level low; nothing here swaps it for a smaller or faster one.

## What changed

- On-device: `SoundAlikeSpelling` treats `ee`/`i`, `oo`/`u` and `th`/`t` as the same spelling, and the on-device vocabulary takes the Dictionary's 256 most important entries (`DictionaryStore.ranked()`) instead of the first 256 stored.
- Gemini prompt: `DefaultWritingRules` is gone (it repeated `PromptV1.rules`); its three unique rules moved into `PromptV1.rules`. The prompt went from about 42k to 32k characters. The Dictionary section no longer gives English-name examples; only the on-device transcript section warns about English look-alikes.
- Screen context: the Mac reads the screen with Vision OCR while the user speaks and sends text, not JPEGs.
- Hedge: the second request starts after `min(2 + speech/20, 20)` s instead of 14–20 s.
- Prompt cache: the fixed part of the prompt is sent once as an explicit Gemini cache and referenced by later dictations.

## Measurements

Orb to Gemini, TTS corpus of 58 clips (Indian English voices, fast and noisy copies, 64-term Dictionary), scripts in `eval/names-latency/`. The Gemini API was noisy on the day; the integrator re-scores with `eval/dictation`.

| Check | main | this change |
| --- | --- | --- |
| On-device Dictionary names (Parakeet v3 + CTC + sound-alike), of 144 | 115 | 122 |
| Same, without CTC | 112 | 122 |
| English-name controls swapped on-device | 3 | 3 (same three) |
| Gemini audio: Dictionary names, of 255 (3 rounds) | 255 | 255 |
| Gemini audio: English controls kept, of 48 | 48 | 47 |
| Gemini text path: English-swapped names fixed, of 58 | 27–34 | 39–41 |
| Latency with 4 screens, p50 / p90 | 5.06 s / 15.97 s | 3.48 s / 7.96 s |
| Calls that spent thinking tokens, with screens | 97 / 116 | 22 / 116 |

Images, not prompt length, made the model think: with four JPEGs attached almost every call produced thought tokens, and those calls are the 15–20 s tail.

## Rejected

- FluidAudio's size-aware CTC defaults (cbw 4.5, minSimilarity 0.50–0.60): they wrote stand-up as Sandeep, Mira as Kiran and Aaron as Arun. CTC stays at cbw 0 and similarity 0.75.
- English-name examples in the Dictionary section (Karen for Kiran): heard from audio, they made Gemini write Kiran for a spoken Karen in 12–15 clips.
- `thinkingBudget: 0` (still thinks on long prompts), `thinkingLevel: minimal` (HTTP 400), streaming (no faster to the last token), the Live API (other models only).

## Verification

`swift test --package-path VoiceIQCore` and unsigned `xcodebuild build` of the VoiceIQ and VoiceIQiOS schemes on an Amp Mac satellite (macos-27). The lobsters-mac-mini runner was not used because this work had to stay in one thread.

## Rollback

Revert the PR. Users' custom rules are untouched; the removed default lines stay in `FormattingSettingsMigration.pastDefaultLines`.
