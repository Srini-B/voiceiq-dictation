# Remove local transcription from iPhone and iPad

The user reported a Nemotron dictation that never delivered text and blocked
the next dictation. Deleting its model also remained busy. The user chose
removal of iOS local functionality as an acceptable resolution. We did not
reproduce or diagnose the underlying inference stall on the physical iPhone.

iOS and iPadOS now compile only the cloud transcription paths. Their target
no longer links VoiceIQInference or VoiceIQSpeech. Local model settings,
download controls, manifests, installers, and session management compile only
on macOS. Cloud real-time transcription remains optional on iPhone and iPad.
macOS retains its existing helper, models, and loading/unloading behavior.

On iOS app launch, remove the two retired local preferences and delete the
app-owned Models directory asynchronously. No inference session must release
it first. Retry deletion on later launches if it fails. Do not change cloud
preferences, writing rules, history, recordings, dictionary, or API keys.

## Verification

- All 143 existing VoiceIQCore tests passed.
- The unsigned Release iOS device archive and Release simulator build passed.
- The device archive passed the bundle audit, which now rejects local inference
  and model-management symbols on iOS. No model weights were bundled.
- iPhone and iPad simulator Dictation settings showed no local model controls.
  The iPhone Privacy Audio row named the cloud provider. Screenshots were inspected.
- Seeded app-owned preferences selected Nemotron with local transcription on.
  Launch removed those preferences, model folders, tools, and partial downloads
  on both simulators. A recording sentinel, writing rule, and cloud real-time
  preference survived.
- Live provider dictation and physical iPhone/iPad execution were not tested.
  No new Mac app runtime test was needed; its inference implementation is unchanged.

## Delivery and rollback

Local source and build verification only. No push, TestFlight upload, or device
installation. Reverting this change restores local support but cannot restore
model files deleted by an upgraded iOS app; those require another download.
