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

## Meetings, PR #82 (Gemini per track plus the on-device far-side split)

Scored by the meetings thread with `eval/meetings/score.py` at 7ad4e32, mean over AMI ES2004a and 8 synthetic calls: **M1 100.0, M2 97.7, M3 96.2, M4 94.9** (main with the speaker model: 95.0 / 92.2 / 87.8 / 84.0). AMI alone: 100.0 / 84.7 / 81.9 / 79.2. AMI's remaining gap is transcription (33% plain WER), which the meeting request can't take hints for while it asks for timestamps.

**M5 notes, judged by Claude Fable 5.2: 85.3 mean, 4 of 9 meetings at 90+.** No invented commitments, no wrong owners. The misses: actions left in prose instead of the action list (s3: 1 of 4 listed), actions without an owner although the speaker was known, a recorded problem dropped (AMI budget), six sections for a 69-second call, and a date carried from one item to another. Notes become a follow-up PR; #82 merges on M1–M4.

**M5 after the notes follow-up (meeting-notes-quality, round 3): 92.6 mean, 8 of 9 at 90+, nothing invented.** Round 2 lost s2's action items (the model returned none); the fix is structural: when notes have no actions but the transcript has "I'll / I will / I can / I'm going to" lines, the app asks once more with those lines quoted. AMI stays at 88 (unowned generic next step, flip-top cost caveat missing).

## Scorers (owner's direction, 2026-11-26)

- Claude Fable 5.2 is the scorer of record for every item. The scripts' numbers count once Fable accepts or corrects them.
- Gemini Neon, through the Antigravity CLI on the BlueLobster runner, is a second reviewer of each PR and of main before each release. Its review is weighed with Fable's scores before a merge or release.

## Fable's baseline rulings for main 517c65d

Accepted: D1 67.9, D2 97.5, D3 89.2, D5 0, M1 100, M5 92.6. Corrected:
- **D4 cleanup: 91.3 → 89.5.** The long dictations are now judged for cleanup too, and a dropped spoken clause caps a case at 70. long_01 drops "Thanks, Srini." in both rounds (68 each).
- **M2–M4:** the per-meeting mean let eight 70-second synthetic calls outvote the 17-minute AMI meeting. `meetings/score.py` now pools totals across meetings. Fable's duration-weighted estimate for main after #82 and #84: **M2 ≈ 89.8, M3 ≈ 87.6, M4 ≈ 85.4**.
