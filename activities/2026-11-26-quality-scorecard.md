# 2026-11-26: Quality scorecard and the main baseline

## Why

cyron rates dictation 75/100 and meetings under 40, and wants 90+ on every item, with dictation at 3 s or less from key-up with every option on (he sees 15–20 s with screen context on). Feature work now runs in parallel threads, so one repeatable scorecard decides when a change is better and when main is ready to release.

## Decisions

- **Scorecard in `eval/`** (`eval/SCORECARD.md`): dictation items D1–D6, meeting items M1–M6, each 0–100.
- **The prompt comes from the app's own source.** `eval/promptdump` compiles `PromptV1.swift` with `swiftc` (macOS or Linux), so the eval cannot drift from what the app sends.
- **Claude Fable 5.2 judges** the subjective items in its own thread. The Anthropic API key in the orb has no credit, so the judge is not called from a script.
- **Control swaps cost 10, not 5.** The judge argued a silent wrong name in a sent message costs more than a missed one.
- **Release cadence:** at least two full days between releases; work that merges in between is batched. Only an urgent fix for the current release may go sooner, with the reason recorded here.

## Baseline: main 517c65d (0.7.15 (90) plus the Chrome extension removal)

33 cases, two rounds, gemini-3.8-flash at thinking level low, from an orb, three calls at a time.

| Run | Calls that thought | e2e p50 | e2e p90 | Max | Names | Control swaps |
| --- | --- | --- | --- | --- | --- | --- |
| Screen context on, 4 JPEGs (all options on) | 62 of 66 | 6.16 s | 16.82 s | 34.3 s | 94/96 | 6 |
| 1 JPEG | 30 of 33 | 4.48 s | 20.66 s | 42.7 s | 47/48 | 4 |
| Screen context off | 2 of 33 | 2.83 s | 4.51 s | 7.7 s | 42/48 | 0 |
| Experiment: screen as text, no JPEG | 7 of 66 | 3.33 s | 7.11 s | 20.6 s | 94/96 | 0 |

- **Root cause of the 15–20 s:** any attached screenshot makes gemini-3.8-flash think on nearly every call. The backup request only starts after 14–20 s, so it can't help. The same thinking swaps English names for Dictionary names (Karen→Kiran, Aaron→Arun, page→Paige, Rowan→Rohan).
- **The fix to test:** the screen's text in the prompt instead of images. It kept every on-screen name, removed the swaps and cut thinking to 11% of calls. Handed to the dictation accuracy and speed thread.

Scores with every option on: **D1 67.9 (94/96 names, 6 swaps at 10 each), D2 97.5, D3 89.2, D4 91.3, D5 0.** D6 not scored yet.
- D3: Hinglish spoken in Latin script came back in Devanagari (55).
- D4: spoken "new paragraph" and "exclamation mark" were dropped (50).

Meetings on main are not scored end to end yet. The meetings thread's AMI ES2004a probe of today's mixed request gives about 75% word recall and 73.5% word attribution, with one of four voices lost. That is about M1 75, M3 73 and M4 75, before notes and naming.
