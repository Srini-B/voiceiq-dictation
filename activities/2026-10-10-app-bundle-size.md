# App download size reduction

## Cause and decision

The published 0.5.18 Mac app linked FluidAudio into both the main app and its
speech helper. The helper also linked the app's Core and GRDB code. Both copies
carried unused LuxTTS resources and the optional NemoTextProcessing engine.
No Whisper, Whistle, Parakeet, or Nemotron model weights were bundled.

Separate the inference implementation from Core with a small shared speech
contract. The Mac UI links Core, the helper links inference, and the iOS app
injects the inference factory. Keep both Mac architectures and both local models.
Disable FluidAudio's unused normalization trait and remove its TTS resources
before signing. Refuse unfamiliar resource files on dependency upgrades.

An initial two-target split still put Core and GRDB into the helper and produced
a 38 MB ZIP. The shared contract target removed that accidental dependency.
Release scripts now audit the final artifacts for these unwanted payloads.

## Verification

Measured complete compressed artifacts in bytes, not download estimates:

| Artifact | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| Universal Mac DMG | 75,331,709 | 32,615,308 | 56.7% |
| Universal Mac ZIP | 74,835,030 | 32,240,893 | 56.9% |
| iPhone and iPad app ZIP | 14,273,638 | 7,431,563 | 47.9% |

The Mac baseline is the actual published 0.5.18 release. The candidate was built
with `scripts/release.sh`, signed, notarized, and stapled. Both the app and DMG
passed signature and Gatekeeper checks. The iOS comparison uses identical
unsigned Release device archives and `ditto -c -k --keepParent` compression.
Apple's encrypted, thinned App Store downloads can differ from these ZIP sizes.

- All 143 existing core tests passed.
- Six saved recordings produced identical transcripts before and after the
  change in Parakeet file mode and Nemotron streaming and file modes. All 18
  comparisons used helpers from separately installed signed, notarized Mac apps.
- Both models rejected missing model directories and mismatched frame counts.
  Nemotron streaming also rejected a mismatched frame count.
- The helper exited after 60 seconds idle with its input pipe still open.
- The bundle audit passed for both new apps and rejected the published Mac app.
- Resource trimming passed removal, repeated-run, and unknown-resource checks.
- iOS device archive compilation and shell syntax checks passed.

No cloud cleanup requests or physical iPhone/iPad inference were run. Existing
compiler warnings remain outside this change. Evidence is in local
`.amp/in/artifacts/size-*` logs and audit JSON files.

## Delivery and rollback

This is a local checkpoint, not a published release or a MacBook installation.
The verification build retains version 0.5.18 and build 43. Increment those
before publishing. No user models, preferences, history, or recordings changed.
Rollback requires rebuilding the previous source revision; no data migration
is needed. Build requirements are now Xcode 26+ and Swift 6.2+ for package traits.
Runtime OS requirements are unchanged.
