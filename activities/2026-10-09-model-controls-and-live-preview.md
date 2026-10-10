# Model controls, live previews, and privacy routing

The user requested a clearer model list, live text in the Mac pill, and an Audio
privacy row that reflects local transcription. They requested direct UI work,
without generated design images.

## Decisions

- Use one selectable row per model, with an independent download or trash action.
  Keep delete confirmation and allow model management while local transcription
  is off. Downloads show full-width progress and an icon cancel action.
- Share model controls and privacy routing between Mac, iPhone, and iPad.
  A selected model that is not ready must still disclose cloud transcription.
- Keep partial transcripts separate from authoritative final transcripts.
  Preview streams retain only the newest value and at most 512 characters.
  Clear the pill on finalization, cancellation, or a session change.
- Use FluidAudio's `getPartialTranscript()` for Nemotron previews. Its
  `process(samples:)` return value is empty even when it has recognized words.
  The final result still comes from `finish()`, after exact audio accounting.
- Re-read the earlier pill implementation and its removal thread. Restore its
  separate preview publisher and session checks, not provisional insertion.

## Verification

- All 143 existing core tests passed. A temporary coordinator probe also checked
  preview clearing, authoritative final insertion, and stale-session suppression.
  The temporary test was removed.
- The iOS simulator app built successfully. Inspected the iPhone both-downloaded
  state, model selection, and local Audio privacy row. Inspected the iPad missing
  model and full-width download states, and exercised download cancellation.
- Built through `scripts/release.sh`, signed, notarized, and installed on the
  Mac mini. Gatekeeper accepted the installed app. Inspected both-downloaded
  controls, download progress, and local Audio privacy text. Fixed a missing
  accessibility press action found during this check, then rebuilt and notarized.
- The installed Nemotron helper produced 55 nonempty previews, with 45 distinct
  values, from the saved recording. The longest preview was 512 characters and
  the separate final transcript had 140 words. This was a correctness probe,
  not a latency benchmark.
- Fed synthetic speech into the installed app through Jump Desktop Microphone.
  Inspected the actual recording pill showing Nemotron's changing words and
  pressed Stop. Logs recorded local Nemotron transcription, followed by cloud
  cleanup and best-effort insertion. This does not establish accuracy, insertion
  into an editor, or an end-to-end latency guarantee.
- Cloud-provider preview parsing compiled and passed existing checks, but new
  live-provider sessions were not exercised in this pass.

The source changes remain local. No commit, push, public release, or MacBook
installation was performed for this UI revision.
