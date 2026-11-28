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
- **M2–M4:** the per-meeting mean let eight 70-second synthetic calls outvote the 17-minute AMI meeting. `meetings/score.py` now pools totals across meetings. Pooled with the new scorer for main after #82 and #84 (9 meetings): **M1 100.0, M2 90.5, M3 87.5, M4 85.4** (Fable's duration-weighted estimate was 89.8 / 87.6 / 85.4). Fable accepted all four; M2 stands because AMI alone still scores 84.7 under the new scorer, so the 0.7 comes only from weighting by speech time.

## TTS clips checked against their scripts

The dictation thread found that gpt-4o-mini-tts leaves out a closing "Thanks, <name>.": long_01's audio ends at "…we ship Friday morning." (checked with gpt-4o-transcribe on the last 5 s and on the whole clip). The sign-off was never spoken, so it is no longer in long_01's script. `check_assets.py` now transcribes every clip with a different model and refuses clips whose ending or words don't match. clean_punct was regenerated with a voice told to say the punctuation words aloud.

Effect on main's baseline: D1 names 67.9 → **70.0** (94/94 names; the six English-name swaps remain), D2 97.5 → 97.6. Fable re-scored long_01 at 94 per round (two points for blank lines inside the list), so **D4 of record is 91.6**. clean_punct's 50 came from the old clip, which may not have said the punctuation words; that clip was replaced before it could be checked, so the 50 is unverified. Voiding it would make D4 95.4; above 90 either way. `check_assets.py` passes on all other English clips, including clean_email, whose sign-off was spoken.

## Release gates for the next release (decided 2026-11-26)

Gemini Neon's review of main 884208e found five High issues. Each must be fixed on main, or rebutted in code, before release:
- **Fixed:** finding 3 (meeting notes and transcript names), #87.
- **In review:** findings 4, 5 and 7 (iPhone keyboard Full Access, suggestion strip, vocabulary cap), #89, ready to merge.
- **In review:** findings 1, 2, 9b and 12 (system-audio rebuild loop, mic leak and drift, cellular check, onboarding), #88. Blocked on the onboarding `needsRestart` refresh.

Not gates, to follow soon after:
- **Keyboard memory on dismissal (finding 6).**
- **Secure-field checks (finding 8).** iOS already gives standard secure fields the system keyboard.
- **#81 and #83**, held for these reasons:
  - Tidy deletes words the speaker meant.
  - The 2 s backup request fires on most dictations and doubles billed calls.
  - Full-display OCR runs with no secure-field or password-manager guard.
  - Sound-alike matching changes sentence-start words ("Feel free" → "Phil").

## PR #83 (dictation accuracy and speed), scores of record

Run on main's clips with the branch's runner, judged by Fable: **D1 100, D2 99.2, D3 96.0, D4 94.3, D5 46.1** (main: 70.0 / 97.6 / 89.2 / 91.6 / 0).

With every option on, dictation went from p50 6.2 s / p90 16.8 s to **3.0 s / 8.9 s**. The screenshots became screen text, and model thinking dropped from 62 of 66 calls to 2. The remaining tail is Gemini server time: 14–15 s with no thinking at all.

Decision: merge #83 once Neon's re-review is clean. D5 becomes its own follow-up, with two parts:
- The eval sends the app's real backup request, so D5 is measured the way the app behaves.
- Time comes off before key-up: streaming the audio, or on-device transcription during speech followed by a text-only call.

### c409c44 re-score (Fable)

Scores: D1 100, D2 99.3, D3 94.4, D4 94.3 (96.1 without clean_punct), D5 54.7 (p50 3.31 s, p90 7.56 s).

The commit restores Hindi "10 बजे" and tight short lists. One regression: in Tamil speech, the English word "ready" is now written in Tamil script, scoring 86 in both rounds. Decision: #83 still merges, because both scores are above main and the Tamil case is a follow-up, along with "new paragraph" and D5.

## 0.7.16 batch notes (11:50 UTC)

- #90 (drop on-device writer and Gemini language picker) merged as fc7993c. Release notes must say that a stored "On device" writing setting becomes Off, and that the downloaded model is deleted at launch.
- #81 (Tidy) is held until Fable re-scores the two corrections that dropped words and Neon re-reviews.
- #83 is held until its prompt examples no longer copy eval strings ("Update the README.", "Bump the version.", "दस बजे"). Neon found no High at c409c44.
- #91 (keyboard findings 6 and 8) is merged as 62006dd. Neon found it clean.

### e5ca037: name guard regression (11:58 UTC)

After 137d5a9 reworded the list and hour rules, ctrl_01 ("Karen and Aaron") comes out as "Kiran and Arun" in 6 of 6 rounds at temperature 0. c409c44 gives "Karen and Aaron" in 6 of 6. Scores at e5ca037: D1 80.0 (4 control flips), D2 98.0, D5 60.1.

The only prompt difference between the two commits is that wording, so the name guard flips on unrelated text. Decision: #83 is held until the name rule decides the case on its own, with ctrl_01–03 checked over 4 rounds. The dictation thread owns the fix.

## Cost becomes a scorecard item (C1)

Standing rule from cyron: Gemini cost stays low for dictation and meetings together, and a change that adds Gemini calls or tokens shows its cost before release. Decisions from the dispatcher, under cyron's autonomy rule:

- **The gate.** C1 is scored at the owner's pace: about 160 dictations a month, measured 2026-11-12 to 11-18, plus 4 meeting hours, the cost study's estimate. It must stay under ₹250 a month at the highest announced prices, which are the January 2027 prices, double today's. Scoring: 100 at ₹200 or less, 90 at ₹250. Typical use (600 dictations and 10 hours) is a check; heavy use is reported but not gated.
- **Meetings stay on Gemini.** On device is not a cost lever.
- **Shared cap on extra calls.** The backup request and send-on-pause together may add about 10% extra dictation calls. The backup goes off if the data shows it barely helps p90.
- **Screen text is capped in length,** not turned off.
- **Every release reports** cost per dictation and per meeting hour.

**How it is computed.** Prices come from ai.google.dev, read 2026-11-26, at ₹93 per USD. Prompt text is priced uncached until the app's usage log measures the real cache hit share. The eval's own hit share of about 53% is optimistic, because its calls run back to back.

**C1 at January prices, owner pace, uncached:**

| Commit | Monthly | C1 | Per dictation | Per meeting hour |
| --- | --- | --- | --- | --- |
| main 517c65d | ₹532 | 0 | ₹2.31 | ₹40.7 |
| 0.7.16 | ₹344 | 52.3 | ₹1.13 | ₹40.7 |
| #95 cda61ee | ₹359 | 46.6 | ₹1.22 | ₹40.7 |

At 0.7.16, meetings are ₹163 of the ₹344 and dictation is ₹181. To get under ₹250 with meetings on Gemini, dictation must fall by about half, or the meeting hour must get cheaper. The levers in order are:
1. Byte-stable prompt prefix so implicit caching hits, with cachedIn logged.
2. A shorter prompt, as far as the scorecard holds 90.
3. A cheaper meeting hour on Gemini.

**Standing rule from cyron, later the same day.** Gemini is the default for dictation, writing and meetings. On device is used only in rare cases, about 5% of use at most, only where it clearly helps and scores 90 or more. Moving work on device is never how the budget is met; caching, shorter prompts and fewer extra calls are.

## D3 reweighted toward Tamil-English

cyron never speaks Hindi; his second language is Tamil mixed with English.

**What changed in the cases:**
- D3 now has four Tamil-English cases at full weight, half of D3:
  - ml_ta (existing).
  - ml_ta_2: Tanglish in Latin letters.
  - ml_ta_3: a time and a name.
  - ml_ta_4: a spoken self-correction, "illa illa".
- ml_hi and ml_hinglish drop to half weight.
- Spanish, French and German stay at full weight.
- D4 gains two Tamil-accented English cases (acc_01, acc_02, `ta_en` voice).
- For the new Tamil cases, either Tamil script or all-Latin Tanglish is accepted, as long as it is never translated and English words are never respelled in Tamil script.

**First look on main e477ef9** (6 cases × 4 rounds, unjudged):
- The Tamil self-correction is ignored in 3 of 4 rounds ("Friday … illa illa, Thursday" keeps Friday). The prompt's correction cues are English only.
- ml_ta_3 writes "3:00 மணிக்கு" in 1 of 4 rounds.
- ml_ta_2 writes "Machi" for the spoken "Machan".
- Both accented-English cases are right in 4 of 4.

The dictation thread owns the prompt fixes. Hindi-specific prompt rules stay only if they cost nothing on other languages.

## Later on 2026-11-26

- **#81 (Tidy for writing Off)** merged at c31bbc1.
  - Fable D4 is 97.5 over 320 cases, with no meant word lost.
  - Neon cleared it.
  - Tidy runs only when the user sets writing to Off, and never as a fallback for Gemini.
- **#100 (meeting cost metering, one notes call):** Fable puts M5 at 92.2 against 92.6 on record, which is inside run-to-run variation, so it can merge. The one slip worth chasing is the s2-echo date ("in the evening" without "tomorrow"). Section names also still vary between runs.
- **#97 (streaming and send-on-pause), decided:**
  - **⌘Esc after an early send** cancels in-flight requests and inserts nothing, but it can't unsend audio that already went to Gemini. The privacy policy says so. The exposure is no wider than a normal dictation, because the same audio goes at key-up.
  - **Merge:** #97 merges when CI is green and no review threads are open.
- **#101 (prompt −436 tokens):** dictation cost at January prices goes from ₹1.131 to ₹1.070, and C1 from 52.5 to 56.4. Fable is scoring it. Cut 1 was rejected because it made gemini-3.8-flash think on about a third of calls.
- **Lever 4 (screen-text cap)** is not shipped. The eval's screen text is only 367 characters, so it can't measure either the saving or the risk. Real screen-text sizes come first.

## 2026-11-28: Version numbers follow semantic versioning

Standing rule from cyron: the release owner picks each version by semantic versioning instead of always raising the patch number. Patch (0.7.x) is for fixes only. Minor (0.x.0) is for new features or notable changes. Major (1.0) is for when the app is stable and feature-complete, or a change breaks compatibility. Build numbers keep rising by one per release. The rule is also in AGENTS.md.

The release planned as 0.7.19 ships as **0.8.0 (94)**. It replaces Gemini with AssemblyAI and needs a new key, adds the draft-then-written paste on Mac and iPhone, and adds meeting waveforms with a playback bar. Its notice moved to release-notes/0.8.0.notice.md, and docs and code comments that said "0.7.19" now say "0.8.0". Earlier activity files keep "0.7.19", the name in use when they were written.
