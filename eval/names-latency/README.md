# Dictionary names and latency eval

Scripts behind the 2026-11-26 names and latency work (`activities/2026-11-26-dictation-names-and-latency.md`). They call the Gemini API with the prompt rebuilt from a source tree's Swift files, so two branches can be compared without building the app.

Outputs (audio, manifest, result files) go to `.amp/in/orb-backup/eval/`, which is not committed.

## Corpus

```sh
OPENAI_API_KEY=... python3 eval/names-latency/generate_corpus.py
```

58 clips spoken by `gpt-4o-mini-tts` in Indian English voices, with fast and noisy copies, and a 64-term Dictionary. Categories: Indian names in the Dictionary, harder names, English names that must stay (Karen, Aaron, Nathan when no Dictionary name is meant), sound-alike words, CONTRIBUTING checks, and long dictations.

## Gemini A/B

```sh
GEMINI_API_KEY=... python3 eval/names-latency/bench.py --a /path/to/main --b . --mode audio --rounds 3 --out .amp/in/orb-backup/eval/ab.json
python3 eval/names-latency/breakdown.py .amp/in/orb-backup/eval/ab.json --misses
```

- `--mode audio` sends the recording, as Dictation set to Gemini does. `--mode text` sends a Parakeet v3 transcript (`parakeet_transcripts.json`) plus `text_cases.json`, where names were swapped for English look-alikes, as on-device Dictation with Gemini writing does.
- `--screen-text` adds the OCR text of four chat screens; `--a-images` sends the screens as JPEGs, the way main did before.
- Calls alternate between the two trees clip by clip so API load hits both alike. Each row records latency, thought tokens, cached tokens, Dictionary names written and English names kept.
- `hedge_sim.py` replays measured call times under another hedge delay, `wer.py` scores word error rate, and `prompt_size_probe.py` times one short dictation under cut-down prompts.

## On-device

On a Mac with the FluidAudio CLI built:

```sh
eval/names-latency/run_parakeet.sh <audio dir> <out dir> <vocab file> <label>
swiftc -O VoiceIQCore/Sources/FormattingPipeline/SoundAlikeSpelling.swift eval/names-latency/soundalike/main.swift -o /tmp/sas
/tmp/sas <manifest> <transcripts> <label>
```

`soundalike/main.swift` runs the app's `SoundAlikeSpelling` over Parakeet transcripts and counts Dictionary names written and English controls swapped. `ocr/main.swift` times Vision OCR of screen captures the way `ScreenContextCollector` reads them.

## What the numbers depend on

Latency is orb to `generativelanguage.googleapis.com` and moves a lot with API load: on 2026-11-26 even a 711-token prompt had a 2.6 s median and a p90 over 11 s. Compare variants from the same interleaved run, not across runs.
