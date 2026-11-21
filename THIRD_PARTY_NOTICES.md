# Third-party notices

## Fonts

### Google Sans Flex
- File: `App/Resources/Fonts/GoogleSansFlex/GoogleSansFlex-Regular.ttf` (variable font), with an
  identical copy and license in `iOS/App/Resources/Fonts/` for the iPhone app
- Copyright: Google LLC / Font Bureau (David Berlow)
- License: SIL Open Font License 1.1 — see `App/Resources/Fonts/GoogleSansFlex/OFL-GoogleSansFlex.txt`
- Source: served via Google Fonts (fonts.google.com/specimen/Google+Sans+Flex); binary
  pinned in-repo. The font is used unmodified (the OFL Reserved Font Name clause
  requires renaming if modified).

### Google Sans Code
- File: `App/Resources/Fonts/GoogleSansCode/GoogleSansCode-VF.ttf` (variable font, v7.001)
- Copyright: Google LLC
- License: SIL Open Font License 1.1 — see `App/Resources/Fonts/GoogleSansCode/OFL-GoogleSansCode.txt`
- Source: github.com/googlefonts/googlesans-code (release v7.001), unmodified.

## Sounds

None — no third-party audio ships in this app. The earcons are original works,
synthesized from scratch by `scripts/generate-earcons.py` (sine fundamentals plus
soft harmonics; no samples, no recorded material) and covered by this
repository's Apache 2.0 license. See `App/Resources/Sounds/ATTRIBUTION.md`.

## Swift packages

| Package | License |
|---|---|
| [Sauce](https://github.com/Clipy/Sauce) (Clipy) | MIT |
| [GRDB.swift](https://github.com/groue/GRDB.swift) (Gwendal Roué) | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) (from M8) | Sparkle License (permissive, MIT-style) |

## Vendored libraries

### WebRTC audio processing (AEC3 echo canceller)
- File: `VoiceIQCore/Vendor/WebRTCAEC/CVoiceIQAEC.xcframework` (static library, arm64 and x86_64)
- Source: https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing at `d0569cfa50c1858ee279d77b3fc8870be6902441`, built by `VoiceIQCore/Vendor/WebRTCAEC/build.sh` together with VoiceiQ's own bridge (`bridge/voiceiq_aec.cc`, Apache 2.0)
- Licenses: WebRTC BSD 3-Clause plus its patent grant; Abseil Apache 2.0; PFFFT, Ooura FFT, the WebRTC FFT, and the square-root routine under their BSD-style terms. Full texts are in `VoiceIQCore/Vendor/WebRTCAEC/Notices/`.

## Keyboard data

`scripts/generate-keyboard-data.py` builds `iOS/Keyboard/Resources/lexicon.bin`
and `emoji.txt` from these files, pinned by commit in the script.

### SymSpell frequency dictionaries

- Files: `frequency_dictionary_en_82_765.txt` (word counts) and
  `frequency_bigramdictionary_en_243_342.txt` (word-pair counts), from
  [wolfgarbe/SymSpell](https://github.com/wolfgarbe/SymSpell) at `91fe939`
- License: MIT, Copyright (c) 2018 Wolf Garbe. The counts derive from Google
  Books Ngram data (CC BY 3.0).

### SCOWL / Hunspell en_US

- Used for the capitalized spelling of names and brands ("iPhone", "Monday")
  and which contractions are words. `index.dic` and its affix rules,
  `index.aff`, from
  [wooorm/dictionaries](https://github.com/wooorm/dictionaries) at `8cfea40`.
- License: the SCOWL copyright and permission notice, Copyright 2000-2018 by
  Kevin Atkinson, with the Ispell BSD license for the parts it derives from.

### List of Dirty, Naughty, Obscene and Otherwise Bad Words

- Words on it stay valid but are never suggested. From
  [LDNOOBW](https://github.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words) at `5faf2ba`.
- License: Creative Commons Attribution 4.0 International.

### Unicode emoji

- `emoji-test.txt`, Emoji 17.0, from
  https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt.
- License: Unicode License v3.

### gemoji (emoji names)

- `emoji-words.txt` and `emoji-shortcuts.txt`: names, aliases and tags from
  GitHub's [gemoji](https://github.com/github/gemoji) `db/emoji.json`, as
  FUTO Keyboard ships it (`java/res/raw/gemoji.json` at `31e720dd`).
- License: MIT, Copyright (c) 2019 GitHub, Inc.

## Hex keyboard (iPhone keyboard, slide to type and predictions)

The iPhone keyboard's keys, slide to type, autocorrect and predictions come
from [Hex](https://github.com/anomalyco/hex) by Christopher Langton and
contributors. `scripts/sync-hex-keyboard.sh` copies them, unmodified, into
`iOS/Keyboard/Hex/` from the commit recorded in `iOS/Keyboard/Hex/UPSTREAM`;
VoiceiQ's own code that connects them is in `iOS/Keyboard/Sources/HexGlue/`.

### Hex source

- Files: `iOS/Keyboard/Hex/FullKeyboard/` (from Hex's `ios/HEXShared/FullKeyboard`).
- License: MIT, Copyright (c) 2026 Christopher Langton. Full text in
  `iOS/Keyboard/Hex/LICENSE`.

### Hex typing models

- Files: `iOS/Keyboard/Hex/TypingModel/` (`en.hextm`, `es.hextm`, `de.hextm`,
  `de.capitals`), from Hex's `ios/HEXKeyboard/TypingModel`, unmodified. Hex
  builds them with `ios/scripts/build-typing-model.py` and
  `build-german-capitals.py`.
- Word and word-pair frequencies and German capitalisation shares: Google
  Books Ngram Viewer data, version 3 (2020-02-17), by Google, licensed under
  [Creative Commons Attribution 3.0](https://creativecommons.org/licenses/by/3.0/).
  Hex lowercased the words, summed the 1980–2019 counts, kept only words in the
  lists below, selected informative pairs and quantized the probabilities.
- English spellings: SCOWL 2020.12.07 and VarCon, sizes up to 70, by Kevin
  Atkinson (<http://wordlist.aspell.net/>). Copyright 2000-2018 by Kevin
  Atkinson. Permission to use, copy, modify, distribute and sell these word
  lists, the associated scripts, the output created from the scripts, and its
  documentation for any purpose is hereby granted without fee, provided that
  the above copyright notice appears in all copies and that both that
  copyright notice and this permission notice appear in supporting
  documentation. Kevin Atkinson makes no representations about the suitability
  of this array for any purpose. It is provided "as is" without express or
  implied warranty. SCOWL's inflections come from WordNet 1.6, Copyright 1997
  by Princeton University, all rights reserved, provided "as is" without
  warranties; its other sources are public domain.
- Spanish spellings: RLA-ES, the Spanish Hunspell dictionaries for
  LibreOffice (es_ES and es_MX) by Santiago Bosio and contributors
  (<https://github.com/sbosio/rla-es>), used under the
  [Mozilla Public License 1.1](https://www.mozilla.org/en-US/MPL/1.1/). They
  only decide which words the Spanish model keeps; the dictionaries themselves
  are not included.

### Hex suggestion filter

- File: `iOS/Keyboard/Hex/FullKeyboard/never-suggest.tsv`, from the
  [List of Dirty, Naughty, Obscene, and Otherwise Bad Words](https://github.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words/tree/5faf2ba42d7b1c0977169ec3611df25a3c08eb13),
  © 2012–2020 Shutterstock, Inc., and contributors, licensed under
  [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/).
  Hex lowercased and classified the entries, omitted ordinary, medical and
  search-only terms, and added common slurs, inflections and spelling variants.

### Hex emoji index

- Files: `iOS/Keyboard/Hex/FullKeyboard/Emoji/emoji-index-*.txt`, built by
  Hex from Unicode `emoji-test.txt` 18.0 and CLDR 49 annotations.
- License: Unicode License v3, in
  `iOS/Keyboard/Hex/FullKeyboard/Emoji/LICENSE-Unicode.txt`.

## FUTO Swipe (iPhone keyboard, slide to type and predictions)

The keyboard extension links FUTO's swipe library, which is GPL-3.0. **The
keyboard extension as built and distributed is therefore licensed under the
GNU General Public License v3.0**; its complete source is this repository
plus the pinned library commit below, and `scripts/build-futo-swipe.sh`
rebuilds the prebuilt libraries from them. The rest of this repository keeps
its Apache 2.0 license, which is compatible with GPL-3.0.

### swipe-library

- Files: `iOS/Vendor/FUTOSwipe/` (headers and static libraries built from the
  source, unmodified); used by `iOS/Keyboard/Sources/Swipe/`.
- Source: [keyboard/swipe-library](https://gitlab.futo.org/keyboard/swipe-library)
  at `e8ade0e03bc18e9609e1f56afbd4394049185a99`.
- License: GNU General Public License v3.0, Copyright FUTO Holdings, Inc.
  Full text in `iOS/Vendor/FUTOSwipe/LICENSE`.
- Linked into the same libraries, from ExecuTorch v1.6.0 (the library's
  submodule moved forward from its pinned v1.2.0): ExecuTorch (BSD 3-Clause, Meta Platforms), XNNPACK
  (BSD 3-Clause, Google and Facebook), cpuinfo and pthreadpool (BSD 2-Clause),
  KleidiAI (Apache 2.0, Arm), flatcc runtime (Apache 2.0).

### FUTO Swipe models

- Files: `iOS/Keyboard/Resources/swipe/` `honorable_sturgeon` (encoder, its int8
  `model_int8.pte`),
  `magic_macaw` (QWERTY decoder), `chosen_planarian` (context model, which
  replaced `hungry_jellyfish` on 2026-11-05 and also ranks the suggestion
  bar's predictions and completions), and `scoring.json` (the scoring
  weights for these models), unmodified.
- Source: [futo-org/futo-swipe](https://huggingface.co/futo-org/futo-swipe) at
  `0a9a44bbe4d5b8aa8d1ff579ffc40d4861ae2467`.
- License: FUTO Model Weights License 1.0, in
  `iOS/Keyboard/Resources/swipe/LICENSE.md`. It requires a visible "powered by
  FUTO Swipe" notice, which is the footer of Settings › Typing.

### Swipe dictionary

- File: `iOS/Keyboard/Resources/swipe/words.trie`, built by
  `scripts/generate-swipe-trie.py` from AOSP's `en_US_wordlist.combined.gz` as
  FUTO Keyboard ships it (futo-org/android-keyboard at `31e720dd`), without
  the words it marks offensive or not a word.
- License: Apache 2.0, Copyright The Android Open Source Project.

## Adapted source

### Dictus (iOS host-app return)

- Files: `iOS/Keyboard/Sources/HostAppResolver.swift`,
  `iOS/Keyboard/Sources/HostArbiterActivation.{h,m}`,
  `VoiceIQCore/Sources/Bridge/KnownAppSchemes.swift`
- Source: [getdictus/dictus-ios](https://github.com/getdictus/dictus-ios), adapted
- License: MIT

```
MIT License

Copyright (c) 2026 PIVI Solutions

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### VivaDicta (return URL table)

- File: `VoiceIQCore/Sources/Bridge/KnownAppSchemes.swift`. Dictus ported the
  table of app return URLs and hosts with no way back from VivaDicta; ours
  takes Dictus's copy and VivaDicta's later additions (synced 2026-11-05).
- Source: [n0an/VivaDicta](https://github.com/n0an/VivaDicta)
  (`VivaDicta/VivaDictaApp.swift`), adapted
- License: MIT

```
MIT License

Copyright (c) 2026 Anton Novoselov

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Trademarks

"Google", the Google logo, the Gemini spark, and related marks are trademarks of
Google LLC. "OpenAI" and its logo are trademarks of OpenAI. "Anthropic",
"Claude" and the Anthropic logo are trademarks of Anthropic, PBC. "TinyFish" and its
logo are trademarks of TinyFish. The iOS app bundles each service's favicon
(`iOS/App/Resources/Assets.xcassets/Provider*.imageset`) only to label the key
field for that service; no endorsement is implied. The app icon and menu bar
glyph are original works.
