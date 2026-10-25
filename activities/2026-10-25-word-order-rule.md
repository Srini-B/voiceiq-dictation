# Writing rules: built-in defaults, custom rules, and a word-order rule

2026-10-25.

## Why

A MacBook dictation into Amp (local `fluid-speech-mini`, cleaned by
`gpt-6-astra` at reasoning `low`) kept the spoken order:

- RAW "I'm not gonna log out and log in with my uh Mac to a new account"
  became "I'm not gonna log out and log in with my Mac to a new account".
  The speaker meant "log in to a new account on my Mac".

The rules already fixed word order that broke grammar ("we need to the
staging server deploy the build"). They kept order that was grammatical but
reads jumbled, because "Keep sentence order … phrasing" and "Do not rewrite
an acceptable sentence" protected it.

The new rule could not reach the MacBook. Its user had added one paragraph
(GitButler's `but` commands) to the editable rules, and an edited copy
replaced the defaults completely, so no later change to the defaults reached
that device or the iPhone it synced with. Adding a rule of your own should
not cost you every future default.

## What changed

- `DictationRulesSeed` is now `DefaultWritingRules`. It is built in, always
  sent, and not shown or editable. It gained the word-order rule under
  "Editing discipline": rearrange the speaker's words within a sentence into
  the order a writer would use, change a small connecting word only when the
  new order needs it, never change the meaning or move words between
  sentences, and leave a sentence that already reads naturally. The final
  check asks whether every sentence is in writer's order.
- `PromptV1` always puts `DefaultWritingRules` in the `<rules>` block and
  appends the user's custom rules after a blank line. The section header and
  position are unchanged, so a user with no custom rules gets the same prompt
  as before. Only the custom part is capped at 12,000 characters. The old cap
  covered the whole text and cut the end off the MacBook's GitButler
  paragraph.
- `SettingsStore.customWritingRules` (key `customWritingRules`) holds only
  the user's rules; empty means none. The old `customInstructions` API is
  gone.
- Settings on macOS and iOS show a "Custom rules" editor, empty by default.
  "Reset to defaults" and "Restore defaults" are gone.
- `WritingRulesSync` syncs the custom rules as `writingRules.v2`. Older builds
  keep `writingRules.v1` (the full text) and are never fed custom-only text
  they would read as the whole rules.
- `FormattingSettingsMigration.splitWritingRulesOnce` runs before sync starts
  on both apps. It keeps the lines of a saved full copy that are in no earlier
  default (matched by hash against all 7 past versions and the current one),
  moves the edit time with them, and removes the old keys.

## Verification

Prompt eval harness `.amp/in/wordorder/` (not committed), the method of
`.amp/in/sensefix/`: the app's exact cleanup prompt with the MacBook
dictionary and GitButler paragraph. 14 jumbled sentences (the real one, 8
more, and 5 held out that are not like the rule's examples) and 22 controls
(14 from `sensefix`, 8 with natural order that must stay as spoken, such as
"Tomorrow I'll send the invoice to the client").

| Model | Old rules: fixed | New rules: fixed | Controls (new) |
|---|---|---|---|
| gpt-6-astra, `low`, 3 runs | 25/42 | 42/42 | 65/66 |
| gemini-3.8-flash, thinking `low`, 2 runs | 14/28 | 28/28 | 44/44 |
| gpt-6-astra, `low`, 3 runs, final prompt path (built-in + custom) | n/a | 42/42 | 66/66 |

The one Astra control miss was an HTTP 429, not a wrong output.

Migration harness `.amp/in/rulesplit/` (not committed) ran
`splitWritingRulesOnce` on the MacBook's saved rules, each of the 7 past
defaults, and a past default with one reworded line and two added lines:

- MacBook: exactly the GitButler paragraph, with its edit time.
- Every past default: no custom rules.
- Edited copy: the reworded line and the two added lines.
- A second run changes nothing.

The notarized release build (`scripts/release.sh`, installed on the Mac mini
and then replaced with the original 0.6.6) and the iOS Simulator build both
turned a saved full copy into just the GitButler paragraph on first launch,
and both show it alone in "Custom rules".

Review (PR #19, Greptile and CodeRabbit) found two sync gaps, now fixed:

- A reset to the defaults has an edit time but no text. The migration now
  keeps that time under the new key, so an older copy on another device
  cannot bring the cleared rules back.
- `writingRules.v2` starts empty, and sync uploaded only a fresh edit while
  iCloud showed no value, so migrated rules would never have reached the
  other device. It now uploads when `writingRules.v1` is in the store. Old
  builds wrote that key only after comparing with iCloud or after an edit on
  that device. Other keys prove nothing: `DictionarySync` writes before it
  downloads (Greptile re-review).

`scripts/test.sh`: 143 tests pass. `scripts/build.sh` and
`scripts/build-ios.sh` build.
