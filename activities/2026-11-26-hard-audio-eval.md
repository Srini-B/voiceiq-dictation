# 2026-11-26: Hard real-audio eval and the send-without-reading score

## Why

cyron rates dictation about 75: he still reads and edits some dictations
before sending. The target is a share of dictations that can be sent without
reading them, including cleanup and formatting, not only word accuracy. The
existing scorecard uses TTS clips, which are cleaner than real speech. This
adds a set of real human recordings with human transcripts (accented,
spontaneous, noisy, far-field, whispered, Tamil) and scores it the way Voice
Arena's Dictation Bench does.

How to run it and the dataset licences are in `eval/hard-audio/README.md`.

## Decisions

- **Metric: Voice Arena's ZER/AMEND method.** Wispr's Canto-2 post and Voice
  Arena's Dictation Bench (November 2026) both use a ready-to-send rate. A
  judge model returns each draft with the fewest edits it needs, and code
  counts the edits. ZER is the share of drafts with zero content edits. D7
  ("send-ready") is stricter: it also fails a draft with a form problem, such
  as a missing question mark, a mangled list, wrong script or an artifact.
  For calibration, Voice Arena's published ZER on its full private and public
  set is Wispr Flow 79.4% and the Gemini app 75.8%, with a 3-of-5 judge
  majority.
- **English and Tamil only.** Hindi and Hindi-English corpora (MUCS, Monsoon
  hi-IN) were dropped: cyron never dictates in Hindi. The weight goes to
  Tamil-accented and other Indian English, Tamil with English words, and a
  spread of other English accents.
- **No wTIMIT, Speech Accent Archive or L2-ARCTIC.** wTIMIT needs a licence
  request. The other two are read paragraphs under NC licences and add little
  beyond EdAcc and Svarah. Whispered speech comes from EARS and Expresso
  instead. Neither has Indian-accented whispers, so that combination is not
  covered.
- **Spend stopped.** The Gemini key ran low the same evening (other threads
  spent most of it). On cyron's instruction this work makes no further paid
  calls. Everything below comes from one Gemini pass already paid for, one
  GPT-6 Astra judge pass, and free on-device runs. The second judge (Gemini 4
  Argon) finished 155 of 451 clips and is not used.

## Baseline: main 62835c6 (before #101), Gemini audio, every option on

D7 is provisional (integrator, 2026-11-26): it was measured on main before
#101, and the table below is GPT-6 Astra's. The Gemini 4 Argon pass stays
unfinished because it would bill the empty eval key.

**Second judge.** Claude Fable 5.2 scored a stratified sample of 180 of the
451 drafts blind, with the same rubric and no API calls. The packet and its
verdicts are thread artifacts.

| | GPT-6 Astra | Fable 5.2 | Both agree it's send-ready |
| --- | --- | --- | --- |
| Send-ready on the sample | 60.0% | 66.7% | 57.2% |
| Reweighted to the 451-clip strata | 62.1% | 68.3% | 59.5% |

- **Agreement:** 87.8% on send-ready (Cohen's κ 0.74), 88.9% on zero-edit.
- **Where they split:** 22 drafts. 17 pass under Fable and fail under GPT,
  and 5 the other way.
- **Fable is more lenient:**
  - on unclear words in corpus references, where the draft's reading is the
    sensible one (navigate/negative, pot/part, thinking/things);
  - on dropped openers or closers ("Yes, ma'am", "I guess");
  - on missing content in Tamil references.
- **GPT is more lenient** on inner capitals in product names (PayBridge for
  Paybridge) and on two invented or kept words.
- **Two-judge score:** the both-agree figure (about 60%) is the conservative
  D7, Voice Arena-style. The spread between judges is about 6 points, mostly
  on conversational clips with doubtful references. On the Voice Arena
  dictations the judges are 2 points apart (76% vs 78% on 50 clips).

One pass, 451 clips. The request is the app's: Dictionary, English (India)
spelling line, place, screen text and the backup request. GPT-6 Astra judged
every clip.

| Stratum | Clips | Send-ready (D7) | ZER | AMEND | WER vs intended |
| --- | --- | --- | --- | --- | --- |
| All | 451 | **64.3%** | 66.1% | 3.39% | 10.0% (English) |
| Voice Arena US dictations | 151 | 85.4% | 86.8% | 0.37% | 4.5% |
| Svarah Indian English | 40 | 85.0% | 85.0% | 0.90% | 7.1% |
| Monsoon, other Indian states | 60 | 70.0% | 71.7% | 2.57% | 15.5% |
| Monsoon, Tamil Nadu speakers | 60 | 56.7% | 60.0% | 2.91% | 15.1% |
| IndicVoices Tamil | 50 | 40.0% | 42.0% | 7.66% | CER 20.7% |
| Whispered | 28 | 50.0% | 57.1% | 20.3% | 24.1% |
| EdAcc other accents | 32 | 28.1% | 28.1% | 9.44% | 18.3% |
| CHiME-6 far-field | 30 | 26.7% | 26.7% | 15.7% | 26.2% |

- **Latency:** end to end p50 3.22 s and p90 6.87 s, with the 0.39 s app
  overhead added. 3 of 451 calls thought. The backup request fired on 67
  calls (14.9%), above the 10% extra-call budget; PR #105 removes it.
- **Cost:** a median prompt of 8.0k tokens, about ₹0.47 per dictation with
  backups at today's gemini-3.8-flash prices. At cyron's 160 dictations a
  month that is about ₹75. When the price doubles on 2027-01-01, it is about
  ₹150. The ₹250 ceiling (`eval/cost.json`, owner profile) also covers 4
  meeting hours, about ₹143 in December and ₹163 from January, so the total
  is about ₹218 in December (inside) and about ₹313 from January (over).
  Dictation alone is not what breaks the budget, but it has no room to
  grow.
- **Caveats:** the dictation-style strata (Voice Arena, Svarah) are close to
  cyron's use. The conversational strata (Monsoon, EdAcc, CHiME-6,
  IndicVoices) are cut from longer talk, so some clips start or end
  mid-thought, and their human references contain errors. A clip-level
  cross-check against Fluid Speech Pro shows about one judged content fix in
  seven points toward a doubtful reference (13 of 97 that could be decided).
  One judge is noisier than Voice Arena's five; the Fable second judge
  above covers 180 of the drafts, not the whole set.
- **Monsoon, Tamil Nadu speakers:** `monsoon_more.py` topped the stratum up
  without checking the speakers already in it, so its 60 clips come from 51
  speakers, and 9 of them have two clips each. The scores are unchanged; the
  script now records `speaker_id` and checks against it.
- **Case:** AMEND's normalisation lowercases, so a case-only fix
  ("Paybridge" to "PayBridge") counts as zero edits. That is a limit of the
  method, and it slightly flatters names.

## Failure classes

Counted over the 161 drafts that were not send-ready. One draft can fall in
several classes. They come from the judge's one-line reason, checked by hand
on every stratum.

| Class | Count | Where | Examples |
| --- | --- | --- | --- |
| Wrong word (mishearing) | 76 | everywhere, most on Tamil-accented English, CHiME-6 and whispers | "item" for "time", "Goa" for "go", "dessert" for "dead cert", "Air Force" for "actual" |
| Content dropped | 50 | conversational strata, CHiME-6 | a short answer ("We did.", "That's the thing.") lost at the start of a clip; part of a far-field sentence lost |
| Filler kept | 42 | IndicVoices Tamil (12), EdAcc, Monsoon, Voice Arena (6) | Tamil வந்து kept as filler in 11 Tamil drafts; "you know", "I mean", "like" as a pause; "Yes, yes" and "Okay, okay" |
| Name spelling | 12 | Voice Arena, CHiME-6 | Halverson/Halvorsen, Tomas/Thomas: a spelling the audio cannot settle (the Dictionary's job) |
| Invented text | 8 | whispers with background talkers, CHiME-6 | a background talker's sentence written instead of the whisperer's |
| Form only | 8 | short questions, fragments | a question spoken with rising intonation and no question word, written without "?" |
| Empty output | 5 | CHiME-6 (3), whispers with background talk (2) | `<<NO_SPEECH>>` on clear speech, both attempts |
| Slang kept on purpose | 2 | Voice Arena | "89 bucks", "3 grand": the prompt keeps slang as spoken, and AMEND's rubric does not |

Fluid Speech Pro's raw transcript was right on 3 of the 5 empty clips ("Can you just use
a wipe for the dining table?"). On both background-talker clips it wrote the
whisperer, not the background voice.

## On-device (Fluid Speech Pro and Mini), free runs

Both ran on a Mac satellite over the 401 English clips, loaded as
`ParakeetSession` loads them, without English-tools rescoring. Decoding took
about 0.14 s per clip. The table shows raw WER against the intended text,
which counts the fillers they keep:

| Stratum | Gemini (written) | Pro raw | Mini raw |
| --- | --- | --- | --- |
| Voice Arena dictations | 4.5% | 8.5% | 9.5% |
| Svarah | 7.1% | 8.9% | 7.7% |
| Monsoon, Tamil Nadu | 15.1% | 11.8% | 11.6% |
| Monsoon, other states | 15.5% | 12.1% | 12.2% |
| Whispered | 24.1% | 11.8% | 14.0% |
| EdAcc | 18.3% | 21.4% | 22.4% |
| CHiME-6 | 26.2% | 21.3% | 25.6% |

Gemini's WER includes the rewording that the Polish rules ask for and its
empty outputs (3 on CHiME-6, 2 on whispers), so it overstates Gemini's word
errors, while Parakeet's raw WER counts the fillers it keeps. The
Tamil-accented and far-field gaps are small enough that rewording alone could
explain them. The whispered gap (24.1% vs 11.8%) is not, and Parakeet decoded
3 of the 5 empty clips. Raw on-device output cannot be sent without reading:
it keeps fillers and has no layout. D7 was not measured for on-device: with
Gemini writing it needs paid calls, and a WER table does not give a D7
score (Pro's 1 − WER is above 90 on Voice Arena and Svarah, but that counts
words, not send-ready drafts). With no on-device D7 at 90 or above, on-device
stays a rare fallback.

## Proposed fixes (prompt fixes parked: no paid Gemini eval credit)

All proposed changes go against current main (after #101). The A/B for each
is a pass over the affected strata, with ctrl_01–03 and the names cases from
`eval/dictation`, and a check of `thoughtsTokenCount`. A rule edit made the
model think on a third of calls in #101's tests.

### Prompt (PromptV1.swift): parked, evidence for later

Standing decision (2026-11-27): there will be no paid Gemini eval credit, so
no prompt change merges without a measured Gemini result. Each fix below is
recorded with its failure class, the baseline clips it targets, the proposed
wording and why it is untested, so it can be picked up from cyron's
real-use data instead. Clip IDs are from the eval manifest and the drafts
from the judged baseline (GPT-6 Astra judge, main 62835c6, before #101).
Neither is in the repository on purpose: the manifest holds dataset
transcripts under their own licences, some non-commercial, and the results
hold model output. The manifest is rebuilt for free by the `fetch.py`,
`monsoon_more.py` and `chime6.py` steps in `eval/hard-audio/README.md`, into
the data folder (`HARD_AUDIO_DATA`, default `.amp/in/orb-backup/hard/`). The
judged file, `eval/hard-audio/results/main-62835c6.gpt-only.judged.json`
(a local, untracked file), needs a paid `run.py` pass at 62835c6 and then
`judge.py`. The `ivta_*` and `edacc_*` IDs are positions after a seeded
shuffle in `fetch.py`, so re-fetching from changed mirrors can move them.
`judge.py` reuses `judge-cache.jsonl` from the data folder when it is
there. Every fix is untested for the same reasons: a
measurement needs a Gemini pass over the affected strata plus the
`eval/dictation` controls (ctrl_01–03, names), and a rule edit can make the
model think and add latency (a third of calls did in #101's tests). Neither
can be judged from the prompt text alone. Notes per fix say what else is
uncertain.

1. **Background voices.** Class: invented or background text (8 drafts).
   - Targets: `whisper_t6_task6_ex02_whisper_00092_bg25` (the background
     talker's sentence was written instead of the whisper) and
     `whisper_t6_task6_p061_sentences_02_whisper_bg25` (same). Possibly the
     CHiME-6 invented trailing fragments `chime6_S09_U02_1124`,
     `chime6_S09_U02_4194` and `chime6_S02_U04_7219`, where cross-talk may be
     the source; that is unverified.
   - Wording (audio section, `THE DICTATION`): "Write only the person
     dictating, the nearest main voice. Speech from other people in the
     room, a TV or a call in the background is never written, even when it
     is louder for a moment."
   - Also uncertain: it could make Gemini drop a quiet dictating voice that
     is not the loudest one, which would move clips into the empty class.
2. **Quiet speech is speech.** Class: empty output (5 drafts).
   - Targets: `chime6_S02_U02_5077`, `chime6_S02_U02_5333`,
     `chime6_S02_U04_3071`, `whisper_t6_task6_ex02_whisper_00272_bg25`,
     `whisper_t6_task6_p058_sentences_01_whisper_bg25`. Gemini answered
     `<<NO_SPEECH>>` twice on each. Fluid Speech Pro heard words on 3 of them,
     so the speech is audible.
   - Wording (answer format). Change the no-speech sentence to: "If no one speaks any words at all, "text" is
     exactly <<NO_SPEECH>>. Quiet, whispered, distant or noisy speech is
     speech: write what you can hear." A recording of only hesitation
     ("um, uh") must still be <<NO_SPEECH>>, as the `clean_filler` control
     expects, so the A/B has to include it.
   - Also uncertain: the 47-clip silent key-press set (see
     `2026-11-26-empty-answer-on-device.md` on the unmerged #107 branch,
     `empty-answer-on-device`) shows the opposite risk. A
     model that writes distant speech also writes the TV and the colleague,
     so this needs the silent set measured on Gemini too, not only the 5.
3. **Spoken question intonation.** Class: form only (8 drafts).
   - Targets, where a missing "?" is the only fix: `va_dict_0641`,
     `whisper_t2_ex02_whisper_00294`,
     `whisper_t4_task4_ex04_whisper_00274_bg10`. Partly:
     `whisper_t6_task6_ex01_whisper_00362_bg25`, `ivta_027`,
     `mon_69959962_126_15_136_98` (each also has a word fix).
   - Wording (audio section): "A sentence the speaker asks with a question's
     rising intonation is a question and ends with "?", even without a
     question word."
   - Also uncertain: the judge reads intonation from the reference text, not
     the audio. `va_dict_0641` ("I wanted to ask if you're still selling that
     bike") is an indirect question, where a period is also correct.
4. **Fillers in every language.** Class: filler kept (42 drafts).
   - Targets, where the filler is the only fix: Tamil வந்து in `ivta_010`,
     `ivta_011`, `ivta_021`, `ivta_031`, `ivta_045`; "you know" or "I mean"
     in `mon_04033483_360_84_371_49` and `mon_11184882_97_71_110_97`; an
     acknowledgement said twice in `mon_60019742_568_89_579_72` and
     `mon_75034733_156_12_170_58`. Partly: `ivta_003`, `ivta_016`,
     `ivta_019`, `ivta_022`, `ivta_033`, `ivta_038`, `edacc_israeli_0`,
     `mon_77394935_459_24_469_32`.
   - Wording (the "Remove speech artifacts" bullet): "Filler is filler in
     every language: Tamil வந்து, அது வந்து and பார்த்தீங்கன்னா used as a
     pause go, as do "you know" and "I mean" used as a pause, and an
     acknowledgement said twice ("yes, yes", "okay, okay") is written once."
   - Also uncertain: வந்து is also the verb "came", and Tamil is not
     covered by `eval/dictation`'s controls, so a wrong deletion would go
     unnoticed. The "like" drafts in Voice Arena (`va_dict_0152`,
     `va_dict_0179`, `va_dict_0229`, `va_dict_0231`, `va_dict_0407`,
     `va_dict_0461`) and EdAcc are a judge-strictness
     question. The current rule already removes filler "like"; this wording
     does not change it. Main already lists "you know" under "Strip
     unnecessary words" and "repeated words" under "Remove speech
     artifacts", so a later edit should merge this wording into those
     bullets rather than repeat it.
5. **Short answers that carry meaning.** Class: content dropped (50 drafts;
   this fix covers a small part).
   - Targets: `chime6_S02_U04_5756` (dropped "We did.") and
     `chime6_S09_U02_2127` (dropped "That's the thing."). Both are at the
     start of the clip, not the end, so the closing-throwaway rule is not
     what removed them, and narrowing it would not fix them.
     `mon_99625420_469_5_482_43` lost a closing "Yeah.", which the current
     rule drops on purpose and the judge wanted kept. That is a disagreement
     about the rule, not a defect to fix.
   - Wording, replacing the earlier "narrow the closing-throwaway rule": add
     to the "Remove speech artifacts" bullet: "A short answer that carries
     meaning ("We did.", "That's the thing.") is content wherever it is said,
     not a throwaway."
   - Also uncertain: both targets are cut from longer conversations
     (CHiME-6), where the clip boundary makes an opening answer look like a
     stray. That is not cyron's dictation style, so the gain may be eval-only.
6. **Tamil whole hour.** Class: format (judge did not flag it).
   - Target: `ivta_048` wrote "11:00 மணி". The judge's own fix kept "11:00",
     so this is a style call from reading the draft, not a counted miss.
   - The numbers bullet's "in every language, never with ":00" added" was
     already live at 62835c6 (it came in 137d5a9), so that rule did not fix
     it. Naming Tamil was already tried in
     `2026-11-26-prompt-cost.md`: a Tamil whole-hour line gave ml_ta_4 3/4,
     no gain, for about 100 more tokens, and Tamil sentences in place of the
     Hindi ones gave ml_hi 1/3 and ml_ta_4 2/3, with one call thinking.
     Neither was kept. Measured again on 2026-11-27 with Tamil added next to
     the Hindi example (see below): it holds the regression slice and fixes
     `ivta_048`, so it merged.

### Prompt fixes measured on a prepaid route (2026-11-27)

cyron added two prepaid keys for testing these fixes only. Each A/B sends the
app's exact request: the prompt from main's `PromptV1.swift` via promptdump,
FLAC inline, temperature 0, thinking low, the `{"text"}` schema, no backup
request, and the app's one re-send on an empty answer.

**Routes.**
- OpenCode (`/inference/google/v1beta`, native Gemini body) answered every
  request with HTTP 429 "inference service is overloaded", so it was not
  used and cost nothing.
- OpenRouter (`google/gemini-3.8-flash`, pinned to Google AI Studio with no
  fallback, audio as `input_audio` FLAC) passed the fidelity check.
  - The request fingerprint matched the baseline's on all 5 check clips.
  - Answers differed in small wording, about as much as two OpenRouter runs
    differ from each other: 20 of 40 regression clips came back identical
    across runs.
  - On the regression slice, the control scored 7.8–9.3% character edits
    against the references over three runs. Gemini direct scored 7.8% at
    62835c6.

**Slice (no full 451 run).**
- The clips each fix targets, as listed above.
- A regression slice of 40 clips that were send-ready in the baseline,
  across all 8 strata.
- 12 talk, TV and call clips from the silent key-press set.

Scoring was free: AMEND-normalised character edits against the human
references, plus a check per fix. No judge model was used.

| Fix | Regression slice (control 7.8–9.3%) | On its targets | Verdict |
| --- | --- | --- | --- |
| 1 Background voices | 9.5% | No gain; 7 of 12 silent clips written, control 5–6 | Dropped |
| 2 Quiet speech is speech | 8.5% | 2 of 4 empty clips recovered; silent inserts 7 of 12, control 5–6 | Dropped: more false inserts |
| 3 Question intonation | 9.1% | No "?" added on any target | Dropped |
| 4 Fillers (வந்து, பார்த்தீங்கன்னா, "I mean", doubled yes) | 10.0%, 11.0% | Tamil filler-free on 6–7 of 11 (control 0–1); deleted the meaningful "பார்த்தீங்க அப்படின்னா" on `ivta_005` | Dropped: regresses |
| 4b வந்து only, "not as the verb came" | 8.6%, 7.9% | Tamil filler-free on 3–6 of 11 | Parked: thinking on 6–7 of 57 calls, control about 1% |
| 5 Short answers carry meaning | 9.9%, 9.4% | Kept 2 of 3; answered empty on passing `chime6_S02_U02_3799` in both runs | Dropped |
| 6 Tamil whole hour ("பதினொரு மணி" → "11 மணி") | 8.1%, 9.0% | `ivta_048` "11 மணி" in both runs (control "11:00 மணி" in all 3) | Merged as its own PR |

Not tested: the `eval/dictation` controls (ml_hi, clean_filler and others).
Their TTS audio is not on hand, and making it needs the OpenAI key. Fix 6
adds Tamil next to the Hindi example rather than replacing it, which was
the variant that cost ml_hi in `2026-11-26-prompt-cost.md`.

**Spend:** OpenRouter $3.38 over 866 calls; OpenCode $0. Latency is not
reported for these routes.

### Pipeline

1. **Empty answer → on-device transcript.** When Gemini answers
   `<<NO_SPEECH>>` or empty for a recording that has speech, the app today
   sends the same audio once more. When Fluid Speech is downloaded, send its
   transcript to Gemini as text instead (`PromptV1.transcriptSection`). That
   is the same number of calls and a cheaper text request. Pro's raw
   transcript was right on 3 of the 5 empty clips here; the Gemini writing
   step on it was not run. PR #107 built this and is parked: on 47 key
   presses with no near-field speaker Pro wrote background speech on 35, and
   no level gate kept 2 of the 3 recoveries at 1 false insert or fewer.
2. **On-device transcript as a hint (Mac with Fluid Speech Pro).** Pro
   decodes during or right after capture (about 0.14 s for a 15 s clip). Add
   its transcript to the audio request as a labelled second opinion, with no
   extra call and about 60 more prompt tokens (₹0.004). It agreed with the
   judge's correction in 54 of 97 content misses. It needs a guard against
   copying Parakeet's own errors and fillers, so it must be A/B tested on
   Voice Arena and names before it ships.
3. **Backup-request rate: dropped.** PR #105 turns the backup request off,
   so the 14.9% backup share goes away.

## Not done

- Fable scored 180 stratified drafts, not the whole baseline, so the
  two-judge score is a reweighted estimate.
- No proposal is measured. There is no paid Gemini eval credit, now or
  later, so the prompt fixes wait for evidence from cyron's real use, and D7
  stays provisional as scored.
- Voice Arena's 3-of-5 judge panel is not reproduced, and its 151 public
  clips are only part of its set, so this ZER is not directly comparable to
  the published leaderboard.

## Rollback

Eval tooling only: delete `eval/hard-audio/` and the D7 row in
`eval/SCORECARD.md`. `eval/dictation/run.py`'s `call` now accepts no audio
(an on-device transcript sent as text); with audio, its behaviour is
unchanged.
