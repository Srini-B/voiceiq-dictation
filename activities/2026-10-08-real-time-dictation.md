# Optional real-time dictation

2026-10-08. Local implementation, not published or installed on the MacBook.

## Decision

Restore direct Gemini and OpenAI streaming for Dictation, Ask Anything,
Translate and Agent. Meetings remain on their existing recording pipeline.
One provider account and key cover transcription and writing, including the
existing screenshot-aware cleanup. No gateways or extra transcription provider.
Keep an independent raw transcript before cleanup and validation.

The setting is off by default. Live quotas and costs differ from batch.
The app keeps the CAF and uses batch transcription when a live result is
incomplete. It never accepts partial words as a finished transcript.
The three-second "Still working" notice is unchanged. Faster transcription
cannot guarantee that cleanup, web search or agent execution meets that time.

## Verification

- `scripts/release.sh` passed all 143 existing tests, built the Release app,
  signed it and notarized the app and DMG. The final app was installed in
  `/Applications/VoiceiQ.app`; Gatekeeper accepted its notarization.
- Synthetic microphone playback through the installed final app completed
  with `gemini-3.5-transcribe-live` and `gpt-live-transcribe`, followed by each
  provider's writing model. Logs showed live completion, not batch fallback.
  Both returned "Send the revised report to Priya by Friday." from speech
  that corrected Thursday to Friday. Usage records paired live transcription
  and cleanup under the same session IDs.
- Final-build pipeline times were 2.95 s for Gemini and 3.22 s for OpenAI,
  one run each. Cleanup requests took 2.61 s and 2.33 s. These are functional
  samples, not a speedup benchmark; History excludes microphone finalization
  and these results do not establish a sub-three-second stop-to-result time.
- `scripts/build-ios.sh` passed. macOS and iPhone simulator settings were
  rendered and inspected with real-time transcription both on and off.
- Forced network failure, long multi-turn speech, and live Ask/Translate/Agent
  execution were not verified end to end. Existing tests cover the shared
  coordinator's prior paths, not all newly restored transport behavior.
- No new regression test cases were added, as requested by repository guidance.

## Rollback and delivery

Turn off Real-time transcription to use batch again. This does not change
provider credentials, meetings, writing rules or saved recordings. Changes
remain uncommitted. No push, release publication or MacBook install was made.

## Quota and session-limit follow-up

The user requested provider-specific refusal handling and no real-time text
on the bottom pill. Read the official Gemini and OpenAI transcription,
session, quota and error documentation. Sources and exact recovery policies
are recorded in `docs/design/architecture.md`.

Added structured failures, Retry-After/RetryInfo-aware admission cooldowns,
separate handling for credit and configuration refusals, and daily quota
suppression. Google project quotas cannot be inferred from an API key.
An unexplained HTTP upgrade 429 remains temporary because URLSession does
not expose a reliable response JSON body there. Suppression is local and
does not prevent batch fallback from encountering the same account limit.

Connections renew only after outstanding turns have completed, before the
documented session caps. Completed text and PCM accounting span connections.
Removed the unused partial-text publication and display bookkeeping. The pill
has no live-text input; partial events only detect transcript stalls.

Verification after these changes:

- All 143 existing tests passed again. No new committed regression cases.
- A disposable direct protocol probe passed structured billing/rate/daily
  classification, a longer retry hint, terminal-refusal reset without bypassing
  a timed cooldown, combined GoAway/final decoding, ordered text across
  connection renewal, and exact accepted-byte preservation. The probe used
  scripted sockets and stubbed usage accounting, not a provider connection.
- `scripts/release.sh` passed, including app/DMG notarization. Installed the
  Release on the Mac mini. Gatekeeper accepted it; installed and built binary
  SHA-256 values matched.
- Synthetic speech through the installed app completed with both live models
  and their respective writing models. Explicit English Samantha playback on
  OpenAI produced the expected raw Thursday-to-Friday correction and final
  "Send the revised report to Priya by Friday." Gemini produced that final too.
  Two earlier default-voice OpenAI samples contained mixed-script words, even
  after adding a microphone startup pause. No general accuracy or latency
  guarantee is inferred from these samples.
- `scripts/build-ios.sh` passed after the shared-core changes.
- Rendered and inspected the installed settings toggle on and off. Captured
  the recording pill while live transcription ran; no live text appeared.
- Real provider quota exhaustion, a full ten/60-minute connection lifespan,
  and forced network failure during recording were not exercised. Scripted
  renewal checks do not prove those provider conditions end to end.

Restored the Mac mini's selected provider to Gemini and removed the temporary
real-time and audio-muting overrides. The setting remains off by default.
No MacBook installation, commit, push or release publication was performed.

## Authorized MacBook installation

2026-10-08. The user requested a signed, notarized build installed on the
MacBook. Ran `scripts/release.sh` again against the current local changes.
All 143 existing tests passed; Apple accepted app and DMG notarization.

Transferred the stapled app ZIP to `verify-macbook` and installed version
0.5.17, build 42, at `/Applications/VoiceiQ.app`. Signature verification and
stapled-ticket validation passed on the MacBook. `spctl` reported Notarized
Developer ID, with the machine's existing `security disabled` override; no
security setting was changed. The installed executable SHA-256 matched the
Mac mini's release artifact. Launched the installed app with Cua Driver and
confirmed its process remained running. No dictation was recorded on the
MacBook during installation verification.

Preserved the previous app at
`~/.local/state/cross-device/jobs/voiceiq-live-20261008/previous-VoiceiQ.app`.
Rollback requires quitting VoiceiQ and restoring that bundle to `/Applications`.
History, credentials and preferences were not changed. Real-time remains
opt-in under Settings → Dictation. Source changes remain uncommitted; no push
or release publication was performed.
