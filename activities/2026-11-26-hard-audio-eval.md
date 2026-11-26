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

D7 is provisional (integrator, 2026-11-26): one judge, on main before #101.
A second judge (Fable 5.2, on a stratified 180-draft packet, no new API
calls) is in progress, and the Gemini 4 Argon pass stays unfinished because
it would bill the empty eval key.

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
  ₹150, still inside ₹250.
- **Caveats:** the dictation-style strata (Voice Arena, Svarah) are close to
  cyron's use. The conversational strata (Monsoon, EdAcc, CHiME-6,
  IndicVoices) are cut from longer talk, so some clips start or end
  mid-thought, and their human references contain errors. A clip-level
  cross-check against Fluid Speech Pro shows about one judged content fix in
  seven points toward a doubtful reference (13 of 97 that could be decided).
  One judge is noisier than Voice Arena's five. Fable has not scored this
  yet.

## Failure classes

Counted over the 161 drafts that were not send-ready. One draft can fall in
several classes. They come from the judge's one-line reason, checked by hand
on every stratum.

| Class | Count | Where | Examples |
| --- | --- | --- | --- |
| Wrong word (mishearing) | 76 | everywhere, most on Tamil-accented English, CHiME-6 and whispers | "item" for "time", "Goa" for "go", "dessert" for "dead cert", "Air Force" for "actual" |
| Content dropped | 50 | conversational strata, CHiME-6 | a short closing "We did." or "that's the thing" removed as a throwaway; part of a far-field sentence lost |
| Filler kept | 42 | IndicVoices Tamil (12), EdAcc, Monsoon, Voice Arena (6) | Tamil வந்து kept as filler in 11 Tamil drafts; "you know", "I mean", "like" as a pause; "Yes, yes" and "Okay, okay" |
| Name spelling | 12 | Voice Arena, CHiME-6 | Halverson/Halvorsen, Tomas/Thomas: a spelling the audio cannot settle (the Dictionary's job) |
| Invented text | 8 | whispers with background talkers, CHiME-6 | a background talker's sentence written instead of the whisperer's |
| Form only | 8 | short questions, fragments | a question spoken with rising intonation and no question word, written without "?" |
| Empty output | 5 | CHiME-6 (3), whispers with background talk (2) | `<<NO_SPEECH>>` on clear speech, both attempts |
| Slang kept on purpose | 2 | Voice Arena | "89 bucks", "3 grand": the prompt keeps slang as spoken, and AMEND's rubric does not |

Fluid Speech Pro decoded 3 of the 5 empty clips correctly ("Can you just use
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
it keeps fillers and has no layout. On-device with Gemini writing was not
measured, because it needs paid calls. No stratum shows on-device at 90 or
above, so on-device stays a rare fallback.

## Proposed fixes (parked: no paid A/B runs while the key is empty)

All proposed changes go against current main (after #101). The A/B for each
is a pass over the affected strata, with ctrl_01–03 and the names cases from
`eval/dictation`, and a check of `thoughtsTokenCount`. A rule edit made the
model think on a third of calls in #101's tests.

### Prompt (PromptV1.swift)

1. **Background voices (audio section, `THE DICTATION`).** Add: "Write only
   the person dictating, the nearest main voice. Speech from other people in
   the room, a TV or a call in the background is never written, even when it
   is louder for a moment." This targets the invented-text class on
   background-talker clips.
2. **Quiet speech is speech (answer format).** Change the no-speech sentence
   to: "If no one speaks any words at all, "text" is exactly <<NO_SPEECH>>.
   Quiet, whispered, distant or noisy speech is speech: write what you can
   hear." This targets the 5 empty outputs.
3. **Spoken question intonation (audio section).** Add: "A sentence the
   speaker asks with a question's rising intonation is a question and ends
   with "?", even without a question word." This targets the form-only class.
4. **Fillers in every language (the "Remove speech artifacts" bullet).** Add:
   "Filler is filler in every language: Tamil வந்து, அது வந்து and
   பார்த்தீங்கன்னா used as a pause go, as do "you know" and "I mean" used as
   a pause, and an acknowledgement said twice ("yes, yes", "okay, okay") is
   written once." This targets 11 Tamil drafts and most of the 30 English ones in the filler class.
5. **Closing throwaways (same bullet).** Narrow "closing throwaways such as
   ... "yeah"" to throwaways that end the dictation with no content of their
   own. Keep a short answer that carries meaning ("We did.", "that's the
   thing"). This targets part of the content-dropped class.
6. **Tamil whole hour (the language bullet, owned by the prompt-cost
   thread).** A Tamil draft wrote "11:00 மணி". The whole-hour sentence should
   name Tamil too ("11 மணி"). Sent to that thread to land with its
   language-neutral rewrite.

### Pipeline

1. **Empty answer → on-device transcript.** When Gemini answers
   `<<NO_SPEECH>>` or empty for a recording that has speech, the app today
   sends the same audio once more. When Fluid Speech is downloaded, send its
   transcript to Gemini as text instead (`PromptV1.transcriptSection`). That
   is the same number of calls and a cheaper text request, and it recovered 3
   of the 5 empty clips here.
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

- Fable has not scored the baseline, and the two-judge score is incomplete.
- No proposal is measured. Each needs a paid pass, which needs cyron's
  go-ahead.
- Voice Arena's 3-of-5 judge panel is not reproduced, and its 151 public
  clips are only part of its set, so this ZER is not directly comparable to
  the published leaderboard.

## Rollback

Eval tooling only: delete `eval/hard-audio/` and the D7 row in
`eval/SCORECARD.md`. `eval/dictation/run.py`'s `call` now accepts no audio
(an on-device transcript sent as text); with audio, its behaviour is
unchanged.
