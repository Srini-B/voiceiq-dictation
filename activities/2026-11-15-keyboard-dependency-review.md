# Keyboard dependency review (2026-11-15)

**Why.** We checked every dependency of the iPhone keyboard extension, its
predictions and Slide to Type against upstream, and moved each one that is
safe to move to its newest release.

**What the keyboard depends on.** The extension links only `VoiceIQBridge`
(this repo, no third-party packages), Apple's UIKit, SwiftUI, `UITextChecker`
and `UILexicon`, and the vendored FUTO Swipe library. It makes no network
calls. Its data comes from the pinned files below.

| Dependency | Ours before | Latest upstream | Outcome |
|---|---|---|---|
| FUTO swipe-library (GPL-3.0) | `1b13f2c8` | `e8ade0e0` (2026-11-13) | Pin moved. The two new commits add CI and pass `scoringPath` through the Android JNI wrapper. The `swipe_decoder` sources, headers, patches and ExecuTorch submodule are unchanged, so the committed static libraries were not rebuilt. |
| ExecuTorch, inside swipe-library | v1.2.0 | v1.6.0 | Moved to v1.6.0 and the static libraries rebuilt (see below). FUTO still pins v1.2.0. |
| torch (`torchgen` at build time only) | 2.10.0 | 2.15.0 | Moved to 2.15.0, ExecuTorch v1.6.0's `torch_pin.py`. |
| FUTO Swipe models (Hugging Face) | `315d4258` | `0a9a44bb` (2026-11-12) | Pin moved. Every model file we ship is byte-identical; `honorable_sturgeon/metadata.json` gains a record of a new int8 encoder. |
| int8 encoder `model_int8.pte` | not shipped | new | Adopted; replaces `model_fp32.pte` (see the last section). It needs no quantized kernels: all its quantized ops run inside the XNNPACK delegate. |
| AOSP word list (swipe dictionary) | android-keyboard `31e720dd` | file unchanged since 2014 | Already the newest. |
| gemoji names via FUTO | android-keyboard `31e720dd` | file unchanged since 2026-06-22 | Already the newest. GitHub's gemoji v4.1.0 stops at Emoji 15.0. |
| SymSpell word and pair counts | `91fe939` | `91fe939` | Already the newest. |
| SCOWL/Hunspell en (wooorm/dictionaries) | `8cfea40` | `8cfea40` | Already the newest. |
| LDNOOBW blocked words | `5faf2ba` | `5faf2ba` | Already the newest. |
| Unicode emoji-test.txt | Emoji 17.0 | Emoji 18.0 (2026-09-16) | Not moved. No iOS draws Emoji 18.0 yet (expected around iOS 27.4), as decided in 2026-11-05-emoji-17.md. |

No license changed. The model weights license (`LICENSE.md`) and
`scoring.json` at the new revision are identical to ours.

**What changed.** `scripts/build-futo-swipe.sh`, `iOS/Vendor/FUTOSwipe/SOURCE`
and `THIRD_PARTY_NOTICES.md` carry the new pins, and
`honorable_sturgeon/metadata.json` is the new revision's file. The library's
metadata parser finds each field at its first match, and every field it reads
comes before the new `int8` block.

**Verified.**
- `scripts/build-ios.sh` (Simulator, Debug) exits 0; the keyboard target's
  warnings are the existing deprecations and one `-Wdocumentation` in the
  vendored `beam_search.hpp`.
- The library's own `src/model_metadata.cpp` at `e8ade0e0`, run on the old and
  new `metadata.json`, reads the same encoder: honorable_sturgeon, en_qwerty,
  64 keys, scoring gamma 0.1017, lambda 0.0373, beta 2.1745.
- iPhone 18 Pro Simulator, iOS 27.0, VoiceiQ keyboard in Safari: the empty bar
  offers The, I, I'm; "the quick" completes to quickest, quick, quickly and
  predicts on, and, way; slides give see, to, up, we. The unmodified build
  gives the same words and bars; slide alternates vary between runs with drag
  timing on either build. No FUTO Swipe, model or ExecuTorch errors in the
  keyboard's log.
- Not tested: curved slides of long words (the Simulator driver drags only
  straight lines), and a device.

## ExecuTorch v1.2.0 to v1.6.0

**Why.** v1.6.0 fixes silently wrong XNNPACK outputs with quantized ops and
adds schema-version and bounds checks on model files. FUTO's library still
pins v1.2.0, so we checked whether it runs on v1.6.0 before moving.

**What carries over.** FUTO's one ExecuTorch patch (`-fexceptions` on the
XNNPACK backend) is not upstream in v1.6.0 and still applies. The flatcc
`grisu3` fix is still needed (same flatcc commit). Our deployment-target edit
is dropped: v1.6.0 builds flatc and flatcc for macOS 14.0 itself when
targeting iOS. v1.6.0 refuses a model whose schema version is above 0; all
our `.pte` files and the int8 encoder are `ET12`, version 0, so none needs
re-exporting. ExecuTorch's license is unchanged.

**What changed.** `scripts/build-futo-swipe.sh` checks out ExecuTorch v1.6.0
in the library's submodule, uses torch 2.15.0 in a venv keyed by version, and
the four static libraries in `iOS/Vendor/FUTOSwipe/lib` are rebuilt by it on
an Apple Silicon test Mac (9 min 45 s, no other script change).

| Library | v1.2.0 | v1.6.0 |
|---|---|---|
| iphoneos `libfutoswipe.a` | 7,095,912 | 7,587,800 |
| iphoneos `libfutoswipe_registry.a` | 225,968 | 347,784 |
| iphonesimulator `libfutoswipe.a` | 6,899,008 | 7,554,264 |
| iphonesimulator `libfutoswipe_registry.a` | 225,792 | 347,168 |

The committed libraries grow about 0.6 to 0.8 MB per SDK. The keyboard
binary's size change was not measured.

**Verified.**
- swipe-library host build against both runtimes, first 4,931 swipes of
  FUTO's swipe.futo.org test split (4,800 scored), beam 100: every per-swipe
  output line is identical between v1.2.0 and v1.6.0. Top-1 / top-4: fp32
  encoder and decoder 90.60 / 95.04; with `chosen_planarian` and
  `scoring.json` weights 92.00 / 95.35. 2.33 ms per swipe on v1.2.0, 2.32 ms on
  v1.6.0. Unit tests pass on both; `test_metadata` fails on both because the
  library's parser does not know the `contextlm` kind (upstream gap).
- `scripts/build-ios.sh` exits 0 with the same warnings as before.
- iPhone 18 Pro Simulator, iOS 27.0: the bars and slid words (see, to, up,
  we) match the v1.2.0 build; no ExecuTorch, XNNPACK or model errors in the
  keyboard log; footprint after slides 52 MB on both.
- int8 encoder, same harness: 90.71 / 95.02 (92.02 / 95.35 with the context
  model), 1.62 ms per swipe, top word differs from fp32 on 1.8% of swipes. It
  also runs on v1.2.0. In the Simulator it slid the same words and the
  keyboard used 42 MB instead of 52 MB.
- Not tested: a device.

## int8 encoder

**Why.** Its accuracy matches fp32, it decodes faster, and keyboard
extensions run under a tight memory limit, where it saves about 10 MB. The
owner chose it.

**What changed.** `FUTOSwipe.mm` loads `honorable_sturgeon/model_int8.pte`;
`model_fp32.pte` (2.6 MB) is removed and `scripts/build-futo-swipe.sh`
downloads the int8 file (1.0 MB) instead. Its codename is still
`honorable_sturgeon`, so `scoring.json` still applies.

**Verified.** `scripts/build-ios.sh` exits 0 with no new warnings. The
keyboard appex holds only `model_int8.pte` and `metadata.json` for the
encoder and is 1.43 MB smaller (Debug Simulator, 23,986,312 bytes). iPhone 18
Pro Simulator, iOS 27.0: the same bars as before (The, I, I'm; quickest,
quick, quickly; on, and, way), slides give see, up, we and to, and the
keyboard log has no model-load or missing-scoring lines. Footprint after
slides was 42 MB in one run and 50 MB in another, against 52 MB for fp32.

**Rollback.** Revert the commits.
