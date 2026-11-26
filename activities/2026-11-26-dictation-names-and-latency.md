# Dictation: Dictionary names and latency (2026-11-26)

## Why

Indian names in the Dictionary came out as English look-alikes (Kiran as Karen, Srini as Sreeni), and Gemini dictations with screen context took 5 s at the median and 15–20 s at p90. The writing model stays `gemini-3.8-flash` at thinking level low; nothing here swaps it for a smaller or faster one.

## What changed

- On-device: inside a sentence, `SoundAlikeSpelling` treats `ee`/`i`, `oo`/`u` and `th`/`t` as the same spelling when the words are at most two letters apart. A word opening a sentence is never respelled ("Feel free" stays, with Phil in the Dictionary). And the on-device vocabulary takes the Dictionary's 256 most important entries (`DictionaryStore.ranked()`) instead of the first 256 stored.
- Gemini prompt: `DefaultWritingRules` is gone (it repeated `PromptV1.rules`); its three unique rules moved into `PromptV1.rules`. The prompt went from about 42k to 32k characters. The Dictionary section no longer gives English-name examples; only the on-device transcript section warns about English look-alikes.
- Screen context: the Mac reads the frontmost window only, with Vision OCR while the user speaks, and sends text, not JPEGs. Nothing is read while secure input is on or a password manager is in front; OCR still running at key-up is cancelled; each capture gets an equal share of the 6,000 characters; with the setting off no screen text reaches the prompt.
- Hedge: the second request starts at the 90th percentile of the last 20 answer times (4–6 s, 6 s until five have answered; the follow-up below lowered it from 4–20 s and 8 s) instead of 5–20 s from the recording's length. Answer times barely depend on length (median 3.0 s for 0–5 s clips, 3.6 s for 20–60 s, 656 calls) but swing with API load, so recent answers are the better predictor. Replayed in order over the day's 952 measured calls it sends a second request in 9.9% of dictations; p90 goes from 12.8 s to 11.9 s in that replay, which assumes the second call is as fast as a random other call, so it flatters the hedge.

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

## Follow-up after #83 and #93

- Hedge: the backup request's delay is capped at 6 s, and 6 s until five answers are in. With a 20 s cap, calls that thought for 15–25 s pushed the 90th percentile toward 20 s, where the second request rarely answered first (Neon).
- `eval/dictation/run.py` now sends the app's backup request (a copy of `DictationHedge`, first answer wins), records `secondRequests` per call, and `pool_latency.py` scores D5 over pooled sessions. `--hedge-ceiling 20` measures commits before the cap.
- Prompt, Gemini audio path: the real-name sentence goes out only when the Dictionary has entries, and says to write an entry when the speaker is saying it, in their accent or through noise, or when the screen shows it, and to keep a different real name the speaker clearly says. The old wording gave "an entry said in the speaker's accent" as an example of "not a plausible name" and guarded only "a common real name".
- Prompt, all paths: Indian address words and particles ("yaar", "ji", "anna", "da", "na") are ordinary words, not names. The example names in `dictionaryIntro` and `transcriptSection` (Sreeni, Karen, Aaron, Nathan, Warren, Prashant) matched strings in the eval corpus and were replaced with names that appear nowhere in `eval/` or the tests. The language bullet's "Digits follow the same rules in every language" sentence repeated the numbers bullet and overreached for French "15 h"; it is gone.

A/B against main 83b9b23 on the #86-checked clips, Gemini audio with screen text (4 rounds; names 2 rounds):

| Check | main | follow-up |
| --- | --- | --- |
| English names kept (ctrl_01–03), of 12 | 11 | 11 |
| Dictionary names (name_01–10), of 20 | 20 | 20 |
| Hinglish "Bhai" kept, of 4 | 4 | 4 |
| Hindi whole hour without ":00", of 4 | 3 | 3 |
| Tamil "ready" in Latin letters, of 4 | 4 | 4 |
| Spoken "new paragraph" breaks after "ready.", of 4 | 2 | 3 |
| Lists and screen cases, of 16 | 16 | 16 |

The one ctrl_01 miss on each side writes Kiran and Arun for a spoken Karen and Aaron. One follow-up clean_punct round dropped "The release is ready."; main did not drop it in these rounds. Pooled D5 is still being collected (session 1 at 12:36 UTC: main p50 2.65 s / p90 4.21 s, follow-up p50 2.81 s / p90 6.21 s, 33 calls each; one session is noise at this spread).

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
