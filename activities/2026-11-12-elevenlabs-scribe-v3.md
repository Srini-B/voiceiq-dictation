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

## Release 0.7.2 (76)

The maintainer asked for a new TestFlight build and Mac install once the
review rounds on PR #44 were settled, so the fixes can be tested on real
devices before merging. Version 0.7.2, build 76 (0.7.1 was 75). It adds
the Spoken languages picker, the PNGs from PR #1 and every review fix
since 0.7.1. The live transcript stays off while "Hide card and ID
numbers" is on.

Result (test Mac, commit 716f2f7):
- `scripts/test.sh` exit 0 (175 tests), `scripts/build-ios.sh` exit 0,
  `scripts/release.sh` exit 0 (app and DMG notarized and stapled).
- `scripts/release-ios.sh` exit 0; build 76 processed and in TestFlight
  internal testing.
- Spoken languages: Automatic detection by default on both apps; a main
  language plus "Also spoken" sends both codes; going back to Automatic
  clears the others. An English and Hindi dictation kept the Hindi.
- Meetings: the live transcript ran with redaction off. Turning redaction
  on mid-recording stopped and cleared it, and the saved transcript came
  back with the card, expiry, CVV and passport number replaced. With
  redaction on from the start there was no live transcript.
- Play and Download worked for a meeting and a dictation (downloads match
  the recordings). Deleting a meeting while it played stopped playback and
  it did not come back.
- Debug log: two exports on each app, no key in any export, Clear emptied
  it.
- The notarized Mac app was installed over 0.7.1 on a second Mac and
  reads 0.7.2 (76).

## Spoken languages from a list (2026-11-12, PR #44)

The maintainer asked for the free-text Spoken languages field to become a list of
the languages Scribe supports, with automatic detection as the default.
Both apps now show a main-language picker (Automatic detection plus the
101 languages on ElevenLabs' speech to text page, ISO 639-3 codes) and,
once a main language is set, an "Also spoken" list for the others: a menu
of toggles on the Mac, a checklist sheet on iPhone. Clearing the main
language clears the others, since batch Scribe v3 answers 500 to other
languages without a main one. Checked against the API: `language_code=hin`
with `secondary_language_codes=eng` answered 200 in Devanagari, and the
live socket accepted `secondary_languages=hin,eng` with `multilang_mode`.

The same push fixed two review findings in the debug log: custom writing
rules and the meeting owner's name are logged by size only, and a browser
meeting's page is logged by host only (no meeting code).

A second review round found that a meeting retried after turning on "Hide
card and ID numbers" reused windows transcribed without redaction. The
window cache name now includes the redaction mode for ElevenLabs, so such a
retry transcribes again.

## Review fixes, round 3 (PR #44)

From the CodeRabbit and Codex reviews of the branch:

- Live meetings: a track more than a second behind the other is now padded
  with silence up to it and nothing is skipped later. The old "debt" skipped
  the same amount of the track's later audio, and after a real dropout (a
  mic reconnecting) the other track's backlog kept re-padding it, so the
  resumed mic was dropped for the rest of the meeting.
  `ElevenLabsTests.testLiveMixKeepsTheMicAfterItDropsOut` fails on the old
  mix (the last chunk had no mic).
- A late live-transcript update from one recording can no longer show on the
  next (`MeetingEngine.liveGeneration`).
- An ElevenLabs key check answered 429 counts as unreachable, so the key can
  still be saved, instead of being rejected.
- The Dictation pane follows the ElevenLabs key being added or removed.
- Browser speaker names: lit tiles trail voices, so the first 1.5 s of a
  diarizer turn take the name heard after it (name-only path), and talk
  statistics count only time after the recording started. Two
  `BrowserSpeakersTests` cover them and fail on the old code.
- Playback copies: a render cancelled by Stop stops rendering, a render that
  finishes after its recording was deleted or purged never recreates it, two
  renders at once both succeed, a stopped preparation cannot stop newer
  playback, and iOS reactivates an inactive voice session before playing.
- Debug log: the size limit is checked after every 1 MB written, not only
  once a day; the Mac section refreshes its size every 2 s; iOS deletes its
  exported copy when it is replaced, cleared or left.
- `docs/PRIVACY.md`: redaction changes the transcript ElevenLabs returns,
  not the audio it receives.

Not changed: the build number stays 75, matching the uploaded build; it
must be raised before merging.

Follow-ups from CodeRabbit's replies:

- A meeting run reads the transcription endpoints and the redaction setting
  once and uses them for its cache name and every request, so a setting
  changed mid-run can't put unredacted windows in the redacted cache.
- A turn too short to settle a lit name keeps no name for its first 1.5 s,
  so a one-word turn under a late tile keeps its diarizer speaker
  (`testAOneWordTurnUnderALateTileKeepsItsDiarizerSpeaker`, fails on the
  previous code).
- A playback copy published just as retention removed the audio is taken
  back out (removal deletes the audio before `playback/`).
- iOS debug log: a load that ends after Clear or leaving is dropped, and an
  export that reuses the previous name is not deleted.
- Naming skips the first 1.5 s after the speaker changes, so a short reply
  under the last speaker's tile can't take their name
  (`testAWordUnderTheLastSpeakersTileDoesNotTakeTheirName`, fails on the
  previous code).
- Renders go in the temporary `recorded-audio` folder that launch empties,
  so a render cut short by the app quitting leaves nothing behind.
- Each debug-log export gets its own folder (`DebugLog.discardExport`
  removes it), and Clear removes every export, so a late load can't
  overwrite the current share file.
- The 1.5 s naming skip now spans a turn the transcript split at a pause
  (`testATurnSplitAtAPauseStillWaitsForTheTile`, fails on the previous
  code).
- Renders go in a folder per launch, and launch cleanup removes only other
  launches' folders, so it can't delete a render that started right after
  launch.

## Review fixes, round 4 (PR #44)

From a full CodeRabbit review of the branch:

- Meeting redaction also covers `generic_id` and `numerical_pii` (other
  identifiers and numeric personal data). Checked against the API: batch
  Scribe v3 answered 200 to the full list.
- While redaction is on, no live transcript runs. Live redacts only finished
  segments, so its running text and speaker words would show the numbers.
- Meeting window caches are named after the spoken languages too, and a run
  snapshots them, so a retry after changing them transcribes again.
- Browser speaker names read turns in time order; the owner's overlap words
  sit at the end of the word list
  (`testTurnsAreReadInTimeOrderWithTheOwnersWordsLast`, fails on the
  previous code).
- Playback: file names are capped at 200 bytes; on iPhone the player
  deactivates the audio session only when it activated it and no voice
  session holds it.
- Debug log: each Chrome host process writes its own file; agent errors log
  the size of the server's message, not its text; the Mac export copies
  beside the chosen file before replacing it; on iPhone only the latest
  load's result is shown.
- `docs/MEETINGS.md`: Retry follows `meetingSpeechEndpoints`.
- Turning redaction on during a recording stops the live session, clears
  its text and drops its late updates. Not tested: nothing in the test suite
  drives a recording `MeetingEngine`.
