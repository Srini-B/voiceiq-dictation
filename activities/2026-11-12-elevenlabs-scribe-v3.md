# 2026-11-12: ElevenLabs Scribe v3 returns as the transcriber

## Why

The maintainer asked for ElevenLabs Scribe v3 (released 2026-11-10) for dictation,
the other dictation modes and meeting transcripts, with its pricing, every
Scribe option that fits, keyterms, and the new instruction feature so the
transcript reaches the writing model already formatted.

## History checked first

- 2026-09-29 (0.5.3): Scribe v2 and v2 Realtime added. 2026-09-30: meetings
  follow the same choice. 0.5.10: a used-up credit balance answered 401 and
  failed rows as a bad key; fixed to queue them.
- 2026-10-05: removed with Sarvam, MAI and the gateways ("Gemini and OpenAI
  only", so a user needs one account).
- 2026-10-21: back as a third source beside on-device and the provider.
- 2026-10-28: removed again on a one-line request, with no reason given.

Neither removal was caused by a bug in the integration. Kept from those
lessons: ElevenLabs is optional and not chosen by default, so the
one-account setup is unchanged; a used-up balance queues instead of reading
as a bad key; and nothing switches anyone over silently (a new settings key,
since builds from 2026-09 stored `transcriptionSource` and old keys are still
in some Keychains).

## Decisions

- One choice, the transcription provider (a picker: the model provider or
  ElevenLabs), covers every mode and meetings, as the owner asked on
  2026-09-30 and the maintainer confirmed. ElevenLabs only transcribes; the provider
  still applies the writing rules and writes meeting notes.
- Batch only. A Scribe v3 Live version (live dictation, and meetings
  streamed with realtime diarization) was built and run against the API the
  same day; the maintainer then asked for everything to happen after the recording
  stops. With ElevenLabs chosen, the Real-time transcription toggle is
  disabled and shown off on both apps; the stored setting is untouched, so
  choosing Gemini or OpenAI again brings back what the user had. No audio
  goes to the provider's live socket either.
- Smart transcription maps to `no_verbatim` plus `transcript_edit`, a fixed
  instruction that formats (punctuation, capitals, sentences and paragraphs,
  spoken marks and breaks, numbers, the spelling setting) and keeps every
  word. The edited text is used only when it passes `ValidationGate`. A
  first version also asked for lists and self-corrections; against the API it
  lost a correction's meaning and scrambled a spoken list, and its quoted
  examples leaked into the text. Those stay with the writing model.
- Meetings: batch Scribe v3 windows, diarized, word-timed, with keyterms,
  `no_verbatim`, audio events kept as words, and anchor clips. No
  `transcript_edit`: its text has no word times.
- Later the same day the maintainer asked for Scribe v3 Live back for meetings only,
  for its VAD and the improvements for three or more speakers. The release
  post has no list of three improvements; "three" is the speaker count: batch
  Scribe v3 makes 17% fewer speaker errors than v2 on recordings with three or
  more speakers (already used, no parameter), and v3 Live adds realtime
  diarization (39% fewer errors than the next realtime model) and turn
  detection that uses the conversation as well as silence. Batch has no VAD
  option; Live's `turn_prediction` commit strategy is VAD plus turn
  prediction.
- Live alone or live plus batch: measured on two real four-person AMI
  meetings (ES2002a and EN2002a, 180 s each) against the corpus's speaker
  labels. Live: right speaker for 95.0% and 73.7% of its words, 303 and 509
  words. Batch: 93.6% and 67.6%, 328 and 617 words. Live labels a little
  better but drops more words where people talk over each other, and notes
  need the words. Chosen: Live shows the transcript during the call, batch
  makes the saved one. About $0.55 per hour of meeting with dictionary terms
  ($0.30 Live for the whole recording, up to $0.25 batch for its speech),
  against $0.30 for Live alone.
- The request was to use every option available without an Enterprise plan. Entity redaction
  is on every plan (the plan table lists "PII redaction: Yes, API" from
  Free up), so meetings get an opt-in "Hide card and ID numbers": off by
  default because ElevenLabs charges 30% more and it rewrites the
  transcript. Zero retention is Enterprise only. Multichannel turns off
  diarization within a channel, speaker roles only know `agent` and
  `customer`, and the speaker library has no documented way to enroll
  anyone, so none of those apply.
- Spoken languages, a new field: the first is `language_code`, the rest
  `secondary_language_codes`. Secondary codes alone answered 500 every time.
- Prices are the pricing page's table ($0.20/h; keyterms +$0.05; edits
  +$0.07, at least 10 s), not the guides' percentages.

## Verification

Real recordings only (no synthetic audio): a Gmail voice-typing demo
(dictation, 30 s), a WIRED interview answer (Ask, 25 s), a Hindi-English
podcast clip (25 s) and 190 s of a public GitLab product team meeting
(three speakers), from YouTube.

- Linux sandbox, against the API with the app's fields: every request answered 200.
  The meeting came back with three speakers and "[chuckles]" tagged, fillers
  removed, in about 3 s. Two findings changed the code: `numbers_format`
  switches `no_verbatim` off (so it goes only with word-for-word
  dictation), and `transcript_edit` translated the Hindi into English while
  `ValidationGate` accepted it (so `ElevenLabs.keepsNonLatinWords` now
  rejects such an edit and the raw text is used). `ElevenLabsTests` (4)
  pass on Linux; the translation test fails with the guard removed.
- Test Mac, origin/main 17424ad plus these changes: `scripts/test.sh` exit 0 (158
  tests), `scripts/build-ios.sh` exit 0, `scripts/release.sh` exit 0
  (notarized, stapled), 0.7.0 (74) installed from the DMG and tested.
  - Real-time transcription turned on first; with ElevenLabs chosen it showed
    off, disabled (AX enabled=false) with its note, refused a press, and the
    stored value stayed on; back on Gemini it was on and enabled again.
  - Meeting recorded in the app while the meeting clip played: one Scribe v3
    call (188.7 s), 27 segments, three speakers.
  - Dictation into TextEdit with Smart transcription: the Gmail clip inserted
    clean text; the Hinglish clip kept its Devanagari with Detect and with
    "hi, en", no edit rejected. Ask's transcription succeeded.
  - Writing rules, meeting notes and Ask answers were not tested in this
    round: no Gemini or OpenAI key was set up (the calls answered 403 and the
    app fell back to Scribe's text as designed). They were tested on the
    release build below.

- Live meetings, 2026-11-12, Linux sandbox: the app's socket parameters with a
  63-term keyterm library and two languages were accepted by the real API
  (no error event). `ElevenLabsTests` (6) pass on Linux. Redaction with
  `name` added on 30 s of the GitLab meeting: 200, every name `{NAME}` in the
  text and the words.

- Live meetings, test Mac, notarized build of origin/main 17424ad plus these
  changes: `scripts/test.sh` exit 0 (160 tests), `scripts/build-ios.sh` and
  `scripts/release.sh` exit 0. A meeting recorded while the AMI clip played
  (186 s): Live showed Speakers 1 to 3 within the first minute with no
  errors logged, and the saved batch transcript had s1 to s3 plus "You" (the
  test Mac's mic is a loopback of the same audio, so echo cancellation could
  not help). Cost rows matched the price book: Live at $0.30/h with
  dictionary terms, batch at $0.25/h for its speech. Two problems found and fixed:
  the narrow Meetings window kept showing the notes spinner instead of the
  live transcript, and the transcript did not follow new lines.

Not committed or pushed; no release was published.

## Release 0.7.1 (75)

The maintainer asked for one TestFlight build and a Mac install once the
combined build passed. That build carries this work together with five
other changes from the same day:

- loud rooms on and the resting pill off by default;
- live Chrome extension status;
- iPhone dictation statistics;
- Play, Download and kept meeting audio;
- Chrome extension speaker names;
- the debug log.

Version 0.7.1, build 75 (0.7.0 was 74). Only two docs conflicted, both
resolved by keeping both sides.

Result (test Mac, final tree):
- `scripts/test.sh` exit 0 (166 tests), `scripts/build-ios.sh` exit 0,
  `scripts/release.sh` exit 0 (notarized and stapled).
- `scripts/release-ios.sh` exit 0; build 75 uploaded to TestFlight.
- One check failed first: the Mac dictation detail's Retry transcription
  stayed enabled with the audio gone. It was fixed with
  `RetryQueue.canRetry` on Mac and iPhone and rechecked before the upload.
- OpenAI on top of Scribe: writing rules, Ask answers, meeting notes and
  Redo worked.
- The notarized Mac app was installed over 0.7.0 on a second Mac.
