# FUTO Keyboard features, rebuilt (2026-10-31)

**Why.** The owner asked to port FUTO Keyboard's features. From the
inventory, they kept emoji search, emoji suggestions and skin tones; delete
and space-bar slide options; blocked words; and the text-edit panel. They
dropped clipboard history, key haptics and sound, and one-handed or split
modes. FUTO's keyboard code is FUTO Source First 1.1, so each feature is
rebuilt in Swift from FUTO's behaviour, not translated. The emoji names are
gemoji (MIT) as FUTO ships them.

**What changed.**
- `scripts/generate-keyboard-data.py` writes `emoji-words.txt` (each emoji,
  its five skin tones when Unicode has them, its search words) and
  `emoji-shortcuts.txt` (1,735 words that suggest an emoji, ranked as FUTO
  ranks them). `EmojiData` reads both and remembers the last skin tone.
- Emoji panel: a search button, and holding an emoji offers skin tones. The
  hold is tried before the tap; inside the scroll view a plain long press
  lost to the tap.
- Bar: the third slot shows the emoji for the word; holding a word offers
  "Don’t Suggest"; a cursor button opens the edit panel. The search results
  are not in a scroll view: iOS 26 blurs scroll view edges, which blurred
  the whole 44 pt bar.
- `KeyboardPreferences`: `spaceSlide`, `deleteSlide`, `emojiSuggestions`,
  `blockedWords`, each decoding to its default when missing.
- Settings › Typing: Emoji Suggestions, Space Bar Slide, Delete Slide,
  Blocked Words.

**Verified** in the iPhone 17e Simulator (iOS 27.0) on the real keyboard:
"pizza" offers 🍕 and picking it gives "I love 🍕 so"; searching "thumb" and
"fire" finds the right emoji; holding 👍 shows six tones, picking the medium
one types 👍🏽 and "wave" then shows 👋🏽; holding "google" and blocking it
removes it from "goog"; a delete slide of two words and back restored one;
undo stepped back over the delete slide, then over the word typed before it;
the word step moved the cursor a word left; Settings shows the new rows
and the blocked list. Slide to type still types words. 143 core tests pass;
no new crash reports. Not tried: redo, Characters delete slide, Space Bar
Slide Off, copy, cut and paste.
