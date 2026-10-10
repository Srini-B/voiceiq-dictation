# Nemotron speech boundaries

## Decision

The 17:01:26 recording omitted “Once” even when replay started after model load.
The existing queue and captured-frame validation were not dropping its audio.
Applying leading silence to the whole stream restored the opening but changed
other words, including in a control recording. Globally forcing English also
changed later recognition and would undermine automatic language selection.

The fix keeps the primary automatic decode. It adds one silent chunk before
finish so exact-boundary stops receive decoder lookahead. A bounded optional
opening retry uses the detected language, or automatic detection with leading
silence when no language tag was emitted. Only one to three opening words can
be prepended, and only with an exact normalized five-word anchor. The remainder
of the primary transcript stays intact. See `docs/LOCAL_TRANSCRIPTION.md`.

## Verification

- All 143 existing core tests passed. Temporary probes were removed.
- `scripts/release.sh` produced signed, notarized, stapled app and DMG artifacts.
- Installed a separate verification copy on the Mac mini. `codesign --verify
  --deep --strict` and Gatekeeper accepted it as Notarized Developer ID.
- The installed helper passed 17 checks using saved real audio, without external
  padding. The original 32.394-second recording and eight cuts from 3 to 26.88
  seconds restored “Once.” The 6.72-second exact-boundary cut retained audible
  “while,” which the old finalization omitted. Cuts immediately before, at and
  after 8.96 seconds were included.
- Five control recordings, including a 121.59-second recording, produced
  byte-identical primary transcripts. File-mode replay also restored “Once.”
- Deliberately mismatched frame counts rejected the result. A one-second clip
  produced no transcript and retained the existing cloud-fallback behavior.
- Installed-helper streaming finalization for nonempty results measured
  0.074–0.271 seconds, including optional onset recovery and model cleanup;
  the target recording took 0.263 seconds. Samples were submitted faster than
  real time after model load, with each append acknowledged. These are single-run
  Mac mini measurements with existing model caches, not end-to-end microphone,
  cleanup-provider, MacBook or iOS latency guarantees.
- iOS Simulator Release compilation passed. No physical iPhone/iPad inference
  was tested. `git diff --check` passed.

Local evidence is under `.amp/in/artifacts/nemotron-boundary-installed.jsonl`,
`nemotron-boundary-release.log` and `nemotron-boundary-ios.log`.

## Delivery and limits

The temporary Mac mini verification installation was removed after testing.
The signed build was then installed on the MacBook at the user's request.
Signature and stapled-ticket validation passed, and both executable hashes
matched the tested build. Automatic launch was blocked by the automation
permission gate; the installation did not change those permissions.

The user subsequently requested a version bump, commit and push. The shared
version is now 0.5.18, build 43. Project generation and all 143 core tests passed
after the metadata change. The MacBook installation remains 0.5.17, build 42;
the version bump does not rebuild or replace an already installed binary.
Publication uses a dedicated branch because pushing this version change to
main would automatically publish Mac and iOS releases.

The opening gate and timing checks are heuristics, not acoustic alignment or a
guarantee of recognition accuracy. Fewer than five primary words cannot supply
the recovery anchor. Non-English speech was not part of this replay corpus.
The fix cannot recover speech before capture starts or an unfinished phoneme
after capture ends. It does not change idle model lifetime or add cloud calls.

To roll back, remove the onset-recovery call and restore plain `finish()` without
the decoder tail chunk, then rebuild through `scripts/release.sh`. Preserve the
existing frame validation and startup queue.
