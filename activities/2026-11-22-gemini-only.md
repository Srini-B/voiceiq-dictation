# Gemini only: dictation and meetings

2026-11-22. Ships in 0.7.12, merged after #55, #56 and #59 (mini-keyboard).

## Why

cyron asked for Google as the only provider and for the app to do only
dictation and meetings:

- Remove OpenAI and ElevenLabs.
- Remove real-time transcription everywhere.
- Remove Agent mode, Translate and Ask Anything.
- Dictation uses gemini-3.8-flash in one call that transcribes and cleans up.
- Meetings use gemini-3.5-transcribe with diarization and word timestamps.

A later request made these settings permanent and removed their rows:
smart transcription, the writing rules, skipping cleanup on short
dictations, learning from edits, fitting to existing text, reading names from
the screen and better hearing in loud rooms. It also made spelling follow
the system region.

## Decisions

- **Stored keys are deleted on upgrade.** The first launch of 0.7.12 deletes
  the OpenAI, ElevenLabs, TinyFish and agent-provider keys from the Keychain,
  the retired settings and shortcuts, and Agent mode's saved runs
  (`SettingsStore.removeRetiredSettingsOnce`). Nothing can read them any
  more. Deleting the saved agent runs was our call, and it can be undone
  before release.
- **One call per dictation**, with the answer forced to `{"text": ...}`.
  The same design ran in 0.5.0 to 0.5.15. It was replaced on 2026-10-05 by
  transcribe-then-clean-up, and now returns. The schema stops the model's
  re-listening notes from being pasted.
- **Meetings cannot have smart formatting.** Google's Interactions API
  rejects smart mode, and custom vocabulary, together with diarization and
  timestamps. Meetings therefore transcribe verbatim, and gemini-3.8-flash
  writes the notes. Diarization covers up to 8 speakers and 30 minutes per
  request; recordings are already sent in windows of 10 minutes of speech.
- **"Skip cleanup for dictations of 5 seconds or less" no longer makes
  sense.** One call both hears and writes the text, so there is no
  separate cleanup to skip. Skipping would mean writing short dictations
  word for word with no time saved, so the setting is removed rather than
  forced on.
- **Spelling** comes from the system region and the first preferred
  language (`SpellingVariant.system`). It is read for every dictation, so a
  change in Settings takes effect on the next one. A region with no variant
  (for example Germany with English) leaves spelling to the model.
- **Reading names from the screen** never asks for permission itself. It
  uses Screen Recording if onboarding was granted it, and otherwise the call
  window's text through Accessibility, which dictation already needs. It runs
  only while a meeting records, so it adds no time to dictation.
- `scripts/generate-release-notes.py` still uses OpenAI. That is release
  tooling, not the app, so it was left as is.

## Verification

On the Mac mini runner, at 9a0319f:

- `scripts/test.sh`: 154 tests, 0 failures, 1 skipped. The skipped test
  needs a US keyboard layout.
- `scripts/build.sh` and `scripts/build-ios.sh` both exit 0.
- iPhone Simulator (iOS 27): Settings, API Key, Dictation, Privacy, Advanced
  and Cost show only the Gemini key and the remaining rows.

Latency and quality, from an orb in Oregon, on six synthesized dictations of
7–22 s with fillers, a self-correction, a bug list, an email and an
injection-shaped question. Times are client-side model time; key-up to text on a
Mac adds about 0.4 s for finalize, encode and insert.

| Pipeline | Mean | Range |
| --- | --- | --- |
| Scribe v3 + gpt-6.1-terra (0.7.11), 12 runs | 2.7 s | 1.5–3.8 s |
| gemini-3.8-flash, one call | not measured: no Gemini key available | |

The 0.7.11 pipeline averaged 5.74 s from key-up to done on cyron's MacBook
(`2026-11-18-dictation-latency.md`).
