# Slid words no longer take a contact's or Dictionary term's capital (2026-11-15)

**Why.** A tester reported slid words coming out capitalized mid-sentence,
for example "Developer". The 2026-11-05 casing fix
(`2026-11-05-keyboard-casing-affixes.md`) changed only `lexicon.bin`, which
typing uses; slide to type was never checked.

**Cause.** FUTO Swipe returns "developer" lowercase from `words.trie`.
`TypingController.insertSlid` then replaced every lowercase slid word with the
user's spelling of its key whenever one existed. The user's words include
each word of every contact name from `requestSupplementaryLexicon` (a contact
"Apple Developer" gives "Developer"; "Will Smith" gives "Will") and the
VoiceiQ Dictionary. So any common word that is also part of a contact or a
Title Case Dictionary term was capitalized on every slide, whatever the field
context. Typing was not affected for common words: it scores the list's
lowercase word above the user's spelling.

**What changed.**
- `TypingEngine.userSpelling(of:)` returns the user's spelling unless it is
  only a first capital on a word the list has lowercase. `insertSlid` and
  `spelling(of:)` (used for learned word pairs, which feed predictions) use it.
- New `KeyboardTypingTests` target (iOS unit tests, no host) compiles
  `TypingEngine.swift` and `Lexicon.swift` with `lexicon.bin`; it runs in the
  `VoiceIQiOS` scheme.

**Trade-off.** A contact whose name is also a common word ("Will", "Mark")
is slid lowercase mid-sentence; Shift capitalizes it. Spellings with other
capitals ("GitHub", "iOS") and names the list lacks or capitalizes ("Srini",
"London") are unchanged.

**Rollback.** Revert the commit.
