# Fit to existing text

2026-10-05. Local, uncommitted at the time of writing.

## Why

The owner often dictates into a field that already holds text. Sometimes the
dictation continues the sentence before the cursor, and sometimes it starts a
new one. The result needed the right space, comma or period, and capital
letter for each case. Before this change, only the Accessibility insert tier
added a leading space. The paste tier added nothing, and the writing model
never saw the field.

## What changed

- New `SurroundingText` in `VoiceIQBridge`: the text before and after the
  cursor. The macOS app and the iOS keyboard both use it.
- At insert time, the result gets spaces on both sides. With the new setting
  on, it also gets a capital at the start of a sentence, and punctuation the
  field already has is dropped from the front of the result. This now runs on
  the paste tier too, when the field can be read.
- At dictation start, the app stores the text around the cursor. The writing
  model gets up to 300 characters before and 100 after. It decides between
  continuing in lowercase, starting with ". " or ", ", and leaving off a final
  period when the text after the cursor continues the sentence.
- New setting: Settings → Dictation → Fit to existing text (on by default).
  Off sends no field text and adds only the leading space.
- `LearningInserter` tracks the fitted text, so auto-learn does not read the
  fitting as a user edit.
- Fixed a spacing bug: a straight `"` after a word now counts as a closing
  quote, so `said "stop."` + `then` gets a space.

## Decisions

- The insert step never lowercases. It cannot tell "and John said" from
  "and then", so that call belongs to the writing model. With writing rules
  off, a continued sentence keeps the transcript's capital letter.
- The field text goes in the user message, next to RAW, not in the OpenAI
  developer message. Field content must not gain instruction authority.
- The iOS keyboard always fits the result (it has no setting), and the iOS
  writing model does not see the field.

## Found while testing the signed build

- Dictation recorded digital silence from the Mac mini's 8-channel Jump
  Desktop Microphone, while the level meter showed speech. With its default
  channel map, `AVAudioConverter` turns more than two discrete channels into
  silent mono. Reproduced in a scratch program: 8 channels gave peak 0, and
  `channelMap = [0]` gave the signal back. 1 and 2 channels give identical
  output either way. `AudioCaptureEngine` now sets `channelMap = [0]`, as
  `MicTap` already did for meetings. The built-in mic reports 3 channels
  while a call app runs voice processing, so dictation during a call was
  likely affected too.
- History keeps the cleaned text, so a result written as ". Please review it"
  could be pasted again later at the start of a sentence. The fit now drops
  leading punctuation at any sentence start.

## Verification

- 23 spacing and capitalization cases through `SurroundingText.fitted`, run
  in a scratch harness: all pass.
- A temporary XCTest printed the prompt. The field section is in the prefix,
  the field text sits before SECOND and RAW, and with a screenshot the OpenAI
  split keeps the field text out of the developer message.
- `swift test`: 143 tests, 0 failures. macOS and iOS Debug builds compile.
- Signed, notarized build installed in /Applications and driven in TextEdit.
  Synthetic speech went through the Jump Desktop Microphone loopback, and
  `voiceiq://start-hands-free` and `voiceiq://stop` started and stopped each
  dictation. Every case ran `gemini-3.5-transcribe`, then `gemini-3.8-flash`,
  then an AX insert:

  | Field before | Spoken | Field after |
  | --- | --- | --- |
  | `…I think we should` | move the launch to Friday | `…I think we should move the launch to Friday.` |
  | `The report is done` | Please review it by tomorrow | `The report is done. Please review it by tomorrow.` |
  | `All set.` | next we ship the build | `All set. Next, we ship the build.` |
  | `I spoke with` | John about the budget | `I spoke with John about the budget.` |
  | cursor before `is ready for review.` | the new design | `The new design is ready for review.` |
  | `The report is done`, setting off | Please review it by tomorrow | `The report is done Please review it by tomorrow.` |

- Not verified: the paste tier (TextEdit takes the AX insert), the iOS
  keyboard, and OpenAI as the provider.

## Rollback

Turn off Fit to existing text, or revert the change.
