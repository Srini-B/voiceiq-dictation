# FUTO Swipe for slide to type (2026-10-31)

**Why.** After the typing-feel fixes, slides still missed: on 4,931 real
swipes from FUTO's MIT dataset our FlorisBoard-style classifier put the
right word first 75.6% of the time and in the top four 85.0%. The owner
asked to port FUTO Keyboard (futo-org/android-keyboard) and its swipe model.

**Licensing decision.** FUTO's keyboard code is FUTO Source First 1.1
(non-commercial changes only); its swipe library is GPL-3.0; the model
weights are under the FUTO Model Weights License 1.0, which needs a visible
"FUTO Swipe" notice. The owner chose GPL: the app is free, open source and
distributed only through TestFlight. So the keyboard links the GPL library
unmodified, the keyboard extension is GPL-3.0 as distributed
(THIRD_PARTY_NOTICES.md, README), and FUTO's other features will be rebuilt
from their behaviour in Swift rather than translated from Source First code.

**What changed.**
- `scripts/build-futo-swipe.sh` builds swipe-library `1b13f2c8` with
  ExecuTorch v1.2.0 for iPhone and Simulator into `iOS/Vendor/FUTOSwipe`
  (14 MB, committed) and fetches the pinned models (15 MB with the
  dictionary). ExecuTorch's flatc host tools inherit the iOS deployment
  target, which is not a macOS version; the script pins them to macOS 12.
- `scripts/generate-swipe-trie.py` and `MappedTrie.cpp`: a memory-mapped
  dictionary in place of FUTO's 98 MB loader, same accuracy.
- `FUTOSwipe.mm` (Objective-C++ bridge) and `SwipeRecognizer.swift` replace
  `SwipeClassifier.swift`, which is deleted, with its word prior.
- Slides record every coalesced touch with its timestamp; the model reads
  speed.
- Settings › Typing footer: "Slide to Type is powered by FUTO Swipe."

**Verified.**
- Mac, shipped dictionary and models, 4,931 real swipes: 91.7% first,
  95.3% top four, 2.2 ms per slide.
- iPhone 17e Simulator (iOS 27.0), real keyboard, synthetic straight-line
  slides: "see help keyboard the quick brown fox", "as" stays lowercase,
  s→e gives "see"; "hello" drawn as straight lines comes out "help" with
  "hello" second in the bar (real fingers slow at corners; the dataset
  numbers cover that). Keyboard footprint 40 MB after slides. No new crash
  reports. Device build links.
- Not verified on a device: memory against the extension limit and decode
  time on an iPhone.

**Rollback.** Revert the commit; `SwipeClassifier` returns with it.
