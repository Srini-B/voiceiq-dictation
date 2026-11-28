# Keyboard: names, days, places and newer words (2026-11-28)

## Why

VoiceiQ's iPhone keyboard is Hex's (MIT), vendored at `012bdbbe`. Its English
typing model held no names, so "Claude", "Monday" or "London" could never be
swiped (Swipe reads only model words) and typos of them were never corrected
to them. Hex fixed this in `f5819f4c`.

## What changed

- `scripts/sync-hex-keyboard.sh f5819f4c`: the only Hex keyboard commit since
  `012bdbbe`. `en.hextm` is rebuilt with SCOWL's names, days and places and
  recent news words (same 3.6 MB), and `en.spellings` (new, 4.6 KB) gives
  words their own spelling ("ChatGPT", "GitHub"). Corrections to a name take
  its capital (`AutocorrectEngine`), and English swipe drops the 4-nat cost
  that kept "clause" ahead of a swiped "Claude" (`SwipeTyping`).
- `MANIFEST` copies `en.spellings`; patch `0009-voiceiq-unfinished-words` is
  refreshed for the changed `AutocorrectEngine` (same behaviour).
- Credits: THIRD_PARTY_NOTICES.md (Hex commit, SCOWL names, Leipzig Corpora
  Collection news counts, CC BY 4.0).

## Verification

On the lobsters-mac-mini runner (Xcode 27.0, iOS 27.0 Simulator, iPhone 17 Pro), at `63e714a`:

- `swift test --package-path VoiceIQCore`: 331 tests, 0 failures. VoiceIQ (macOS) and VoiceIQiOS build unsigned; `xcodebuild test -scheme VoiceIQiOS` passes.
- Word list through Hex's real key plane and engine (scratch test, not committed), each word swiped through its key centres and 7/5 pt off them:
  - Swipe: main 14/28, this branch 22/28. Claude, Monday, London and Christmas now come out right; on main they gave clause, noonday, longeron/kingdom and christens/christenings. Mary (may) still misses. ChatGPT now gives "chatgpt" (main "chatbot") and GitHub gives "Github" (main gothic/virgin). Controls (the, hello, keyboard, clause, money, about, people) are unchanged.
  - Typed then space, after "I said ": 12/14 on both. claude, mondya, mray, github are right on both; lindon and chatgpt miss on both. Mid-sentence, "ask chatgpt " now becomes "ask ChatGPT" (main leaves it lowercase).
- Size, Debug: VoiceiQ.app +152 KB, VoiceIQKeyboard.appex +12 KB (en.hextm 3,599,997 bytes, en.spellings 4,588 bytes, new).
- Keyboard memory (`footprint`, same steps in Reminders): this branch 33 MB at open, 37 to 39 MB after typing and swipes, peak 50.4 MB; main 30 MB, 37 to 41 MB, peak 49.0 MB. en.hextm stays clean mapped memory (3.5 MB, 0 dirty). Both peaks are above the 44 MB docs/IOS.md gives for iOS 27.2; that is the same on main, so not from this change.

## Review follow-ups (Fable K1 95, agy Neon, Codex)

- Sentence-start casing (patch `0010-voiceiq-spelling-case`): "chatgpt" at a
  sentence's start gave "Chatgpt", because auto-shift's capital hid the word from
  `en.spellings` and Hex's `matchCase` put a capital on "iPhone". A spelling
  with capitals now keeps them in every position, typed, swiped or in the strip;
  with Auto-capitalization off, predictions add none (Codex). `KeyboardTests` is
  now hosted by the app and compiles the keyboard; `SpellingCaseTests` covers
  chatgpt, iphone and hello at and after a sentence's start, with the model
  attached as `FullKeyboardView` attaches it.
- The strip after "Monday " shows three emoji and no words. This is Hex's
  `withStripEmoji`, which gives every slot to a finished word's emoji when it
  has three, and is the same on main. On lobsters-mac-mini, a scratch
  `FullKeyboardView` (393 pt, English QWERTY) showed 😩 ☕ 🙄 after "See you on
  Monday " and 🌤️ ☀️ 🌧️ after "I like the weather " on both main and this
  branch; only the engine's hidden next words differ (main "the, to, and",
  branch "morning, through, to"). Left as Hex ships it.
