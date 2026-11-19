# 2026-11-19: Scribe v3 Live and dictation settings on iPhone

## Why

Release 0.7.9 added real-time dictation with ElevenLabs Scribe v3 Live on the Mac only. The iPhone kept Real-time transcription switched off whenever ElevenLabs transcribed. The goal is the same dictation features on every platform where the platform allows it.

## What changed

- iPhone app and keyboard dictations stream to Scribe v3 Live when ElevenLabs transcribes and Real-time transcription is on, with the Mac's commit limits (a pause after 25 s, 30 s at the latest) and the batch upload as the fallback.
- Settings › Dictation on iPhone: the Real-time transcription toggle is no longer disabled for ElevenLabs and has the Mac's footer; the Spelling picker is added under the writing rules.
- The ElevenLabs provider text on both platforms no longer says Real-time transcription is unused with ElevenLabs, or that Scribe formats the text (that was `transcript_edit`, removed in 0.7.9). PRIVACY.md says the same.
- The Debug-only simulated microphone streams its file to the live socket, so the Simulator can test real-time dictation.

## Checked, no change needed

- `[transcription] timing:` and `[session] timing` come from shared code and are written on iPhone too.
- `transcript_edit` removal is shared code and applies on iPhone.
- Screen context cannot work on iPhone: an app cannot capture other apps' screens.

## Verification

See the pull request: `scripts/build-ios.sh`, `swift test` in VoiceIQCore, and a Simulator dictation with ElevenLabs as the provider and Real-time transcription on.
