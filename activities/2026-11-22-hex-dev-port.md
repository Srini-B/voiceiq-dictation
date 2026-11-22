# 2026-11-22: keyboard ported to Hex dev

The product owner chose to follow Hex's current design before releasing 0.7.12, so the
vendored keyboard moved from Hex 2a023f9 to dev c7e96f18
(`scripts/sync-hex-keyboard.sh c7e96f18`), English only as before.

- The patch was rewritten against dev and keeps three hooks: the strip's frame and slots
  (`FullKeyboardView.stripLayout`), the phone's metrics (`KeyboardMetrics.phoneOverride`),
  and room beside the space bar (`KeyboardLayout.spaceSideRoom`). The space-bar hook now
  insets the drawn space key before touch targets are made, so it covers each of dev's
  bottom-row branches instead of one.
- Hex dev's portrait strip leaves 20 pt above its words and 26 pt below. VoiceiQ keeps the
  38 pt bar and its small chips and widens the gap under it to 14 pt, so the content sits
  midway (conflict with Hex's design, kept as the product owner asked).
- Dev's keyboard adds Add to vocabulary in the strip. Its list is VoiceiQ's Dictionary in
  `HexGlue` (`CustomVocabularySettings`): it reads the Dictionary's words and queues an
  added word for the app, as the dictionary offer does.
- Verified with `scripts/sync-hex-keyboard.sh c7e96f18` leaving the tree unchanged, the
  keyboard build, and KeyboardTypingTests.

Rollback: revert the port commit; the previous pin and patch come back with it.
