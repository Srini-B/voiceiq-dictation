# Dictation: Dictionary names and latency (2026-11-26)

## Why

Indian names in the Dictionary came out as English look-alikes (Kiran as Karen, Srini as Sreeni), and Gemini dictations with screen context took 5 s at the median and 15–20 s at p90. The writing model stays `gemini-3.8-flash` at thinking level low; nothing here swaps it for a smaller or faster one.

## What changed

- On-device: inside a sentence, `SoundAlikeSpelling` treats `ee`/`i`, `oo`/`u` and `th`/`t` as the same spelling when the words are at most two letters apart. A word opening a sentence is never respelled ("Feel free" stays, with Phil in the Dictionary). And the on-device vocabulary takes the Dictionary's 256 most important entries (`DictionaryStore.ranked()`) instead of the first 256 stored.
- Gemini prompt: `DefaultWritingRules` is gone (it repeated `PromptV1.rules`); its three unique rules moved into `PromptV1.rules`. The prompt went from about 42k to 32k characters. The Dictionary section no longer gives English-name examples; only the on-device transcript section warns about English look-alikes.
- Screen context: the Mac reads the frontmost window only, with Vision OCR while the user speaks, and sends text, not JPEGs. Nothing is read while secure input is on or a password manager is in front; OCR still running at key-up is cancelled; each capture gets an equal share of the 6,000 characters; with the setting off no screen text reaches the prompt.
- Hedge: the second request starts at the 90th percentile of the last 20 answer times (4–20 s, 8 s until five have answered) instead of 5–20 s from the recording's length. Answer times barely depend on length (median 3.0 s for 0–5 s clips, 3.6 s for 20–60 s, 656 calls) but swing with API load, so recent answers are the better predictor. Replayed in order over the day's 952 measured calls it sends a second request in 9.9% of dictations; p90 goes from 12.8 s to 11.9 s in that replay, which assumes the second call is as fast as a random other call, so it flatters the hedge.

## Measurements

Orb to Gemini, TTS corpus of 58 clips (Indian English voices, fast and noisy copies, 64-term Dictionary), scripts in `eval/names-latency/`. The Gemini API was noisy on the day; the integrator re-scores with `eval/dictation`.

| Check | main | this change |
| --- | --- | --- |
| On-device Dictionary names (Parakeet v3 + CTC + sound-alike), of 144 | 115 | 121 |
| Same, without CTC | 112 | 120 |
| English-name controls swapped on-device | 3 | 3 (same three; Aaron → Arun comes from main's sound-alike match) |
| Gemini audio: Dictionary names, of 255 (3 rounds) | 255 | 255 |
| Gemini audio: English controls kept, of 48 | 48 | 47 |
| Gemini text path: English-swapped names fixed, of 58 | 27–34 | 39–41 |
| Latency with 4 screens, p50 / p90 | 5.06 s / 15.97 s | 3.48 s / 7.96 s |
| Calls that spent thinking tokens, with screens | 97 / 116 | 22 / 116 |

Images, not prompt length, made the model think: with four JPEGs attached almost every call produced thought tokens, and those calls are the 15–20 s tail.

## Rejected

- FluidAudio's size-aware CTC defaults (cbw 4.5, minSimilarity 0.50–0.60): they wrote stand-up as Sandeep, Mira as Kiran and Aaron as Arun. CTC stays at cbw 0 and similarity 0.75.
- English-name examples in the Dictionary section (Karen for Kiran): heard from audio, they made Gemini write Kiran for a spoken Karen in 12–15 clips.
- An explicit Gemini cache of the fixed prompt: median 2.88 → 2.62 s, but with screen text one clip thought for 25–43 s in 4 of 6 cached calls and never inline.
- A 2 s hedge: it fired on most dictations and doubled billed calls.
- `thinkingBudget: 0` (still thinks on long prompts), `thinkingLevel: minimal` (HTTP 400), streaming (no faster to the last token), the Live API (other models only).

## Verification

`swift test --package-path VoiceIQCore` and unsigned `xcodebuild build` of the VoiceIQ and VoiceIQiOS schemes on an Amp Mac satellite (macos-27). The lobsters-mac-mini runner was not used because this work had to stay in one thread.

## Rollback

Revert the PR. Users' custom rules are untouched; the removed default lines stay in `FormattingSettingsMigration.pastDefaultLines`.
