# WIP Findings: Dictation Accuracy (Names & Sound-Alikes) and Speed

Snapshot handed off from `T-01a216b3-e1bb-73dd-8a5a-8ecb607f53fe` on `main` (`ddcefe1`, 0.7.15 (90)).
No production Swift files have been edited yet.

## 1. Root Causes Found in Code

### On-device CTC Vocabulary Boosting (`VoiceIQCore/Inference/EnglishVocabulary.swift`, `VoiceIQCore/Sources/LocalModels/LocalTranscriber.swift`)
1. **Context biasing boost is disabled (`cbw: 0`) and similarity floor is too strict (`minSimilarity: 0.75`)**, with `spotterRescueEnabled: false`.
   - FluidAudio `v0.18.2` (our pinned SPM dependency) now ships tuned size-aware defaults (`ContextBiasingConstants.rescorerConfig(forVocabSize:)`: `cbw = 4.5`, `minSimilarity = 0.50` / `0.55` / `0.60`), PLUS two key false-positive guards added since the Oct 21 replay:
     - `confidentWordBiasGate: true` (default, FluidAudio #967): strips context bias when TDT heard a word at confidence >= 0.99 unless similarity >= 0.80, protecting ordinary words like `left`, `window`, `sort`.
     - `shortTermCbwTaperPivot` / `shortTermCbwTaperExponent` (FluidAudio #702, recommended opt-in `5` / `2.0`): tapers CBW down for short keywords (like `EFT`, `MCP`) while keeping strong boost for multi-token Indian names.
   - At `minSimilarity: 0.75`, common Indian-to-English confusions are blocked before CTC ever scores them: `Karen/Kiran` (0.60), `Aaron/Arun` (0.60), `Nathan/Nitin` (0.50), `Warren/Varun` (0.50), `Nickel/Nikhil` (0.50), `Colin/Kalyan` (0.50), `Cathy/Karthik` (0.43), `Sarah/Shreya` (0.50), `Freya/Priya` (0.60).
2. **`LocalTranscriber.sessionOptions` drops sorting and `learnedFrom`**:
   - Passes `DictionaryStore().entries().prefix(256)` in raw insertion order instead of starred -> manual -> newest.
   - Passes `aliases: $0.misspelling.map { [$0] } ?? []`, ignoring `entry.learnedFrom` (auto-learned user edits like `"Karen"` -> `"Kiran"`). FluidAudio uses aliases only as candidate forms that still require acoustic CTC confirmation.
3. **CTC encoder runs unconditionally** even when no transcript word matches any dictionary term (FluidAudio `v0.18.2` provides `hasCTCRescoringCandidates` preflight).

### On-device Sound-Alike Spelling (`VoiceIQCore/Sources/FormattingPipeline/SoundAlikeSpelling.swift`)
- Ported from Hex (`db515bda`, English-name biased). Fails on Indian-to-English name pairs:
  - `ee`/`i` and `oo`/`u` are not folded (`Sreenie`/`Srini`, `Deepak`/`Dipak`, `Rajeev`/`Rajiv`, `Pooja`/`Puja` all fail — even `Sreenie`/`Srini` from `OnDeviceDictationTests`).
  - `th` maps to `"0"` in `SoundKey.consonants` instead of matching aspirated `t` (`Karthik`/`Kartik`, `Nithin`/`Nitin`, `Siddharth`/`Sidart`, `Nathan`/`Nitin`).
  - Intervocalic `h` (`Rohan`/`Rowan`) and `v`/`w` (`Varun`/`Warren`, `Vikram`/`Wickram`) never match.
  - Strict `firstVowel` exact equality blocks `Kiran`/`Karen`, `Nitin`/`Nathan`, `Priya`/`Freya`.
  - `maxEdits = 2` runs on unfolded letters (`Nikhil`/`Nickel` = 3 edits).
  - Single-word only; VoiceiQ also does not yet have Hex's `VocabularySpelling` (compound joining like `"Open Code"` -> `"OpenCode"`).

### Gemini Path: Accuracy (`VoiceIQCore/Sources/FormattingPipeline/PromptV1.swift`, `VoiceIQCore/Sources/Settings/DictionaryStore.swift`)
1. `dictionarySections` is buried in the middle of a ~9.4k-token prompt (after `rules` + `DefaultWritingRules`, ~2.5k tokens before examples + `layoutReminder` + `audioSection` + audio).
2. `Vocabulary` wording is written for text transcripts ("transcription mistake"), not audio hearing, and does not warn against English-name substitution bias (Canto-2: balance recall with low false-flip rate).
3. `DictionaryStore.spellings()` caps at 10 explicit `misspelling` entries and ignores `learnedFrom` completely.

### Gemini Path: Speed (`PromptV1.swift`, `DefaultWritingRules.swift`, `GeminiClient.swift`, `GeminiClient+Transport.swift`)
1. `PromptV1.rules` + `DefaultWritingRules.text` = 41,975 chars (~9.5k tokens). `DefaultWritingRules.text` repeats almost all of `PromptV1.rules` and adds a 150-word `"Before returning, check: ..."` checklist.
   - Note: `FormattingSettingsMigration.swift` references `DefaultWritingRules.text` to strip old default lines during migration; any edit to `DefaultWritingRules.text` must preserve removed line hashes in `FormattingSettingsMigration.pastDefaultLines`.
2. `gemini-3.8-flash` API probe findings:
   - `thinkingLevel: "minimal"` -> HTTP 400 (`Thinking level MINIMAL is not supported for this model`).
   - `thinkingLevel: "none"` -> HTTP 400 (`Invalid value`).
   - `thinkingBudget: 0` -> HTTP 200, **but does NOT stop thinking on full dictation prompts** (`long_02` still emitted 438 thought tokens with `thinkingBudget: 0` on full prompt).
3. Hedge timer (`GeminiClient.freshRetryTiming`): `min(max(deadline * 0.45, 5), 20)` (~14–20 s).

## 2. Measurements Captured So Far

### Baseline (`baseline.json`, 26 synthetic TTS clips via `gpt-4o-mini-tts`, 50-term fake dictionary)
- Prompt size: 41,975 chars (~9,589–10,762 prompt tokens).
- Calls: 26 (0 errors).
- Latency: median **2.66 s**, mean **5.61 s**, range **1.90–47.94 s**.
- Thinking spikes: `thoughtsTokenCount > 0` in 3/26 calls (`long_01` 52 s clip hit **47.94 s** with **5,148 thought tokens**; `name_02` 79; `eval_all_filler` 63).
- `long_02` dropped `"Thanks, Rohan."` sign-off (`Rohan` missed, 45/46 Indian name recall on clean studio TTS — need harder fast/noisy Indian-name audio + text-mode misheard-English-name eval to separate dictionary recall cleanly).
- False flips: 0; CONTRIBUTING 6/6 passed except `eval_punctuation` dropped the paragraph break.

### Partial Speed Ablation (Round 1 stopped mid-run on handoff)
- Prompt chars: `full` 41,975 (~9.6–10.1k tok) vs `dedup` (no `DefaultWritingRules`) 29,822 (~7.1–7.6k tok) vs `dedup_norem` (also no `layoutReminder`) 29,027 (~6.95–7.4k tok).
- `name_08` (7 s): `A_full_low` 9.26 s (cache 7405) | `B_dedup_low` 2.62 s | `C_dedup_norem` 2.14 s | `D_full_budget0` 4.12 s | `E_dedup_budget0` 2.66 s | `F_dedup_sysinst` 3.37 s (th=93, cache=0).
- `long_02` (24.5 s): `A_full_low` 5.88 s (th=508, cache=8095) | `B_dedup_low` 4.47 s (th=0) | `C_dedup_norem` 2.81 s (th=0) | `D_full_budget0` 5.64 s (th=438) | `E_dedup_budget0` 16.54 s (th=0) | `F_dedup_sysinst` 5.88 s (th=0, cache=0).
- Notable: `contents` prefix DOES get Gemini implicit caching (7.4k–8.1k cached tokens on repeat calls), whereas `systemInstruction` got `cache=0` on Round 1.

## 3. Parallel Thread Coordination
- `T-01a216b3-af20-75f2-a69e-54d6f01747c6` ("Drop on-device writer, add rule cleanup") messaged that it is editing `GeminiTranscriptionService.swift` (removing `localWriter`/`writeOnDevice`, removing `languages:` arg, adding Hex rule cleanup on writing-Off) and `PromptV1.swift` (removing `languages:` parameter only). It is NOT touching `DefaultWritingRules.swift`, `DictionaryStore.swift`, `ReplacementEngine.swift`, `SoundAlikeSpelling.swift`, or `EnglishVocabulary.swift`/`LocalTranscriber.swift`.
- `T-01a216b3-a2b3-7618-99f4-522331264976` ("Remove the Chrome extension") already opened PR #73.

## 4. What's Left for the Next Thread
1. Add harder Indian-name audio clips (fast/noisy/less-common names like Charan/Sharon, Dinesh/Dennis, Vasanth/Vincent, Sumanth/Samantha, Bharath/Barrett, Kirthi/Kirsty, Dev/Dave, Yash/Josh, Gaurav/Gareth, Saurabh/Sarah, Vamsi/Ramsey, Kiran/Karen, Arun/Aran) + 100-term dictionary + text-mode misheard-transcript eval so accuracy differences separate clearly.
2. Complete interleaved 5-round speed + quality A/B runs (`bench_speed.py` + `bench_gemini.py`) testing deduplicated prompt, dictionary placement/wording, `learnedFrom` soft hints, and hedge timing.
3. Implement and test on-device fixes: `EnglishVocabulary.swift` (FluidAudio 0.18.2 size-aware `cbw`/`minSimilarity` + `shortTermCbwTaper` + `confidentWordBiasGate`), `LocalTranscriber.swift` (sorted vocabulary + `learnedFrom` aliases), `SoundAlikeSpelling.swift` (Indian name phonetic/folding improvements with false-flip test suite), and optional CTC preflight.
4. Run Apple/Xcode verification (`swift test --package-path VoiceIQCore`, `build.sh`, `build-ios.sh`) per routing rules, update docs/activities, open PR, get CI green, resolve review-bot comments.
