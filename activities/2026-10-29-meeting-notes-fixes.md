# 2026-10-29: Meeting notes fixes, speaker diarization and prompt caching on Claude + Nemotron

## Why

The owner's 3 PM Meet call on the MacBook (English throughout, three people)
produced notes the owner was close to dropping the feature over:

1. The notes came back in Hindi; a redo gave English.
2. The owner was "You" everywhere, which reads wrong in notes shared with others.
3. The `…` menu next to Export was an empty bezel on macOS 27.
4. Redo showed no progress while the old notes stayed on screen.
5. One person was "Nithin", "Lithin" and "Nathan"; one deliverable "APK",
   "APA" and "EPK". The notes ignored the Dictionary and writing rules that
   dictation uses.

The owner also asked for Anthropic prompt caching on cleanup and for
Nemotron 3 Diarization to split the far side of Claude + Nemotron meetings.

## Findings

- Hindi: the MacBook's `transport.jsonl` showed the first and the redo
  `meetingSummary` requests byte-identical (15,643 bytes). The model picked
  the language. The language is now detected in code (`NLLanguageRecognizer`)
  and named in the request.
- DeepInfra word timings break above 300 s of audio: the text is complete but
  `words` covers only the last part, stamped past the end of the file.
  Measured on the call's far side: 30, 60, 90, 120, 180, 240 and 300 s cuts
  timed every word; 360 s timed 33 of 309 words; the whole 639 s track timed
  38 of 421, at 797 to 860 s. The first Claude + Nemotron redo of the call
  kept 142 words from 474 s on. Meeting windows on this provider are now
  240 s of speech (`MeetingTranscriber.deepInfraWindowSpeech`); dictation uses
  only the text and is not affected.

## Decisions

- Notes request (`MeetingNotesPrompt`): OUTPUT LANGUAGE line; owner labelled by
  name (typed name, screen owner marker, Settings "Your name in meeting notes",
  else "Note owner") and a rule against "you"; the Dictionary, spellings and
  custom writing rules; a leading `glossary` field that settles one spelling
  per person and term before anything else is written.
- Claude + Nemotron notes run on `claude-sonnet-5-5` (`AnthropicConfig.notesModel`);
  cleanup stays on Haiku.
- Cleanup on Claude sends the rules up to `PromptV1.layoutReminder` as a
  cached `system` block; the PLACE, field and reminder lines follow uncached.
- Diarization: the helper runs Nemotron 3 Diarization alone when
  `LocalMeetingRequest.speechDirectory` is nil, and
  `LocalMeetingTranscriber.relabel` labels the cloud words the way on-device
  words are labelled. Mac only; without the model the track labels stay.
- `MeetingEngine.processing` now maps each meeting to its step, and the Mac
  header and iOS detail show it. "Redo transcript and notes" drops the cached
  words and hears the meeting again; Retry after a failure still reuses them.
- The `…` label depends on the OS. macOS 26 sizes a menu bezel only from text, so it keeps `Text(Image(...))`. macOS 27 drew that label as an empty bezel in the app, so it gets an icon-only `Label` with a 16 pt minimum height, which matches Export. Compared in a scratch window built with the release SDK on both Macs.

## Verification

- Cleanup caching, through the real `GeminiClient.cleanup` with the owner's
  keys and Dictionary: the first dictation sent 12,719 tokens, and the second,
  into a different app, sent 146 and read 12,573 from the cache.
- Notes probe on the 3 PM call's saved transcript, with the MacBook's
  Dictionary and writing rules, three runs on `claude-sonnet-5-5`: all
  English, the person spelled "Nitin" (the Dictionary's spelling) 13 to 17
  times and never "Nithin", "Lithin" or "Nathan", no "APA" or "EPK", and no
  "you". About 7,000 tokens in, 3,200 to 3,700 out.
- Signed and notarized 0.6.12 (57) installed on the Mac mini, on Claude +
  Nemotron with meeting transcription set to the provider and the 3 PM
  call's folder copied in. "Redo transcript and notes" showed "Transcribing"
  in the header over the old notes. It sent three 240 s windows to DeepInfra,
  ran the diarizer alone in the helper (`Local meeting: 0 words, 44 speaker
  stretches in 2.0s`), and wrote Sonnet notes in 25 s. The transcript covered
  3:26 to 10:32 (820 words); the split was owner 373, Aheli 442, Shankhajeet 5,
  close to the on-device pipeline's split of the same call (443, 437, 4).
  The notes were English, named the owner, and spelled "Nitin" 15 times.
- The `…` menu label is visible on the MacBook (macOS 27.0.1) and the
  Mac mini (macOS 26.6.2) with the same build.
- `swift test` in VoiceIQCore: 143 pass. The Mac and iOS apps build.
- The copied meeting folder was deleted from the Mac mini, whose meeting
  transcription setting was put back to on-device.

## Open

- The MacBook's existing notes for the 3 PM call were not redone; Redo notes
  writes them with the fixed request.
- iOS has no field for the owner's name yet; there the owner is "Note owner"
  unless named in the meeting.
