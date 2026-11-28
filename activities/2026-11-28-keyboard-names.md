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

Pending: Mac build, tests, before/after word list and memory on the
lobsters-mac-mini runner; K1 re-score by Fable; Neon via agy.
