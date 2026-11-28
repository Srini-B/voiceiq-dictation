# 2026-11-28: The iPhone draft is swapped by one insert

## Why

The iPhone keyboard's draft (`activities/2026-11-28-draft-then-written.md`)
was switched off the day it was built: in Messages the second dictation's
swap deleted the earlier dictation and the typed text. The swap called
`unmarkText()`, pressed Delete once per character of the draft and typed the
written text. The keyboard's own reading of the field said all of that had
worked. This entry records what a keyboard can and cannot rely on, measured,
and the swap built on it. cyron then turned drafts on
(`KeyboardInserter.offersDrafts`) for the two apps the swap was tried in,
with the Simulator as the evidence: there was no device to try it on.

## What was measured

iOS 27.0 Simulator (24A434), iPhone 17 Pro, VoiceiQ keyboard with a debug
probe that ran `UITextDocumentProxy` calls from a script. The field's real
text was read from outside, as its accessibility value (the page's own
values for Safari); "proxy" is `documentContextBeforeInput`. Each row starts
from `Hi ` and marks `abc` first. `+` joins calls made in one run loop turn,
`,` separates turns.

| Calls after `setMarkedText("abc")` | Messages field | Proxy |
| --- | --- | --- |
| `unmarkText` + `insertText("x")` | `Hi x` | `Hi abcx` |
| `unmarkText`, `insertText("x")` | `Hi abcx` | `Hi abcx` |
| `insertText("xyz")`, `insertText("Q")` | `Hi xyzQ` | `Hi xyzQ` |
| `unmarkText` + `deleteBackward` | `Hi ` | `Hi ab` |
| `deleteBackward` | `Hi ` | `Hi ab` |
| `insertText("abc")` + `insertText("x")` | `Hi abcx` | `Hi abcx` |
| `insertText("abc")` + `deleteBackward` | `Hi ab` | `Hi ab` |
| `unmarkText` + `setMarkedText("new")`, `unmarkText` | `Hi new` | `Hi new` |
| `setMarkedText("xyz")`, `unmarkText` | `Hi xyz` | `Hi xyz` |
| `insertText("abc")` + `adjustTextPosition(-1)`, `insertText("Z")` | `Hi abZc` | `Hi abZ`, `c` after |

- Messages' search field and the app's Try it field (a SwiftUI `TextField`)
  gave the same results for the rows tried there (the first three in Try it,
  all in the search field).
- Safari textarea: the first, second, third and sixth rows as above. Delete
  on marked text took one character and left the rest marked; `unmarkText` +
  `deleteBackward` left `Hi abab`.
- A wait of 0, 20 or 100 ms between `unmarkText` and the next call gave the
  same, correct result: the batch is one run loop turn.
- `setMarkedText("abc")` + `insertText("xyz")` in one turn gave `xyzabc`: the
  insert went in first.
- While text is marked the proxy reports the text before it without it. The
  proxy counts the draft in at `unmarkText`, then goes on counting each call
  as if the host had applied it in order.
- For the keyboard's own calls, `textDidChange` came only after
  `adjustTextPosition` and after new marked text set in the turn of an
  `unmarkText`. `selectionDidChange` never came.
- Send in Messages with `Hi ` and a marked `abc`: the message sent was
  `Hi abc`, the field was empty, and `textDidChange` came with no text
  before the cursor and `hasText` false.
- A tap elsewhere in the field's text moves the cursor when nothing is
  marked. With text marked (one run), the text stayed marked, the proxy's
  text did not change and the keyboard was sent nothing; the next
  `insertText` replaced the marked text where it was.
- A marked draft of about 480 characters with Tamil, Devanagari and a
  family emoji was replaced whole by one `insertText`.

So the first swap failed on the batch rule, not on Messages ignoring
`unmarkText`: `unmarkText` and the first Delete went in one turn, the Delete
was applied first and took the whole marked draft, and the 26 Deletes that
followed took the 25 characters before it.

## What changed

- `KeyboardDraft`: the draft stays marked until one last call. `replace` is
  one `insertText` of the written text. `keep(.beforeEdit)` is one
  `insertText` of the draft's own text, for the turn the keyboard's own edit
  follows in. `keep(.alone)` is `unmarkText`, for turns with no other write.
  `isInPlace` replaces `follow`: it only ever stops a write. No
  `deleteBackward`, no read-back, no `async`.
- `KeyboardDraft.canType`: any script and length, no line break (not tried).
- `KeyboardDraft.verifiedHosts`: drafts only in Messages and VoiceiQ.
- `KeyboardModel`: `textDidChange` and `selectionDidChange` check the draft
  at once; Dictate ends a held draft; a poll that ends a draft with
  `unmarkText` types no result and marks no new draft; a keyboard that has
  been in no field for `moveGap` drops its draft.
- Tests: `HostField` is a fake host with the measured behaviour, where the
  field and the proxy's copy are two texts.
- `KeyboardModel.lastDraftPlace` and `settleLeftDraft` (added after the
  dismissal check below): the first poll of a new input session in the app
  of the last draft sends one `unmarkText`.
- `KeyboardDraft.textBefore` and `KeyboardModel.unmarkQuiet` (added after
  the review below).

## What the other design would have done

`setMarkedText(written)`, then `unmarkText()` a turn later, gave the right
text in the hosts measured (the two in one turn were not measured). Between
the two calls the written text is marked, and a key in that turn would
replace it. One `insertText` has no such state.

Committing with `unmarkText` before the keyboard's own key was the other
half of the same bug: the key replaced the draft. Putting the key off by a
turn would also work; an insert of the draft's own text needs no timing.

## Failure modes left

- A host that makes marked text plain on its own, without a change the
  keyboard sees: the written text lands after the draft, so the dictation
  is there twice. A key typed while the draft is held gives the draft twice.
  Nothing is deleted. This is why drafts are limited to verified hosts.
- A selection made in the moment before the swap, in a host that reports it
  late: the written text replaces the selection, as a typed key would.
- Not measured: a host that drops marked text (a field with `UIKeyInput`
  only), a web editor that ends a composition itself, an app that rewrites
  its field on every change.

## Dismissal check, and what it found

Same probe, Messages, 2026-11-28 evening, on the branch rebased onto the
smart-insert work.

- Keyboard swiped down while the draft was marked: the log read "draft stays
  as heard: the keyboard was dismissed", the draft was plain text, the
  written text was not typed, and a key tapped after refocusing went in
  after the draft.
- Settings opened over a marked draft, then Messages again: the keyboard
  logged the same line 4 to 12 s after Messages left the screen, but back in
  Messages the draft was still underlined. A new keyboard instance was on
  screen and held no draft. `unmarkText` from that instance made the draft
  plain, and the next key went in after it. Without it, UIKit replaces
  marked text with the next insert.
- So the `unmarkText` from `viewWillDisappear` reaches the field when the
  keyboard is dismissed in a visible app, and reaches nothing when the app
  has left the screen. The keyboard cannot tell the two apart, nor whether a
  swap it made in those seconds landed.
- Fix: `lastDraftPlace` and `settleLeftDraft`. After it, the same steps left
  the draft plain on return (log: "new session in com.apple.MobileSMS:
  unmarkText sent"), and a key went in after it.
- The keyboard's process killed while Settings was over a marked draft: the
  new process could not name its app (`HostAppResolver` had an empty pid
  table), sent `unmarkText` all the same, and the draft was plain. In that
  process drafts were not typed until Messages was restarted, since an
  unnamed app is not a verified host; the written text went in alone.
- With nothing marked, the `unmarkText` of a new session left the field's
  text as it was (two runs).

## Review before the push

A reviewing subagent of this thread read the diff at 7221cfe2 (code only,
nothing run) and said not to push. What it found and what was done:

- High: the keys read the text before the cursor from the proxy, which
  leaves the draft out, and only then make their edit. A space after a
  misspelt word with a draft after it would have counted its Deletes from
  that word and, with the draft plain by then, deleted the draft and part of
  the word. Reproduced in the Simulator with the fix switched
  off: `Lets meet Tomorrow tomorow`, a marked draft ` ok`, then space gave
  `Lets meet Tomorrow tomtomorrow `. With the fix the same steps gave
  `… tomorow ok `, and space after a draft `see you tomorow` corrected the
  draft's own word to `tomorrow`. Fixed: `KeyboardDraft.textBefore`, read by the keys;
  `EditController.moveCursor` and `KeyboardModel.insert` make the draft
  plain before they read.
- Medium: `settleLeftDraft` forgot the place after an `unmarkText` in an app
  it could not name, which may have been another app. Fixed: the place is
  forgotten only in the named app; an unnamed session gets one call and the
  place stays.
- Medium, to measure: whether `hasText` is true in a field whose only text
  is a marked draft. Measured: in an empty Messages
  field with only the marked draft, the proxy gave no text before the cursor
  and `hasText` true, and the written text replaced the draft.
- Low: a second poll in the run-loop turn of an `unmarkText` could type a
  result or mark a draft. Fixed: `unmarkQuiet`.
- Not changed: tests that state the fake's measured behaviour stay, since
  the fake is the record of the measurements; a key tapped in the same turn
  as a lone `unmarkText` is still not covered.

## Verification

- Mac mini, `KeyboardTests` on the iOS 27.0 Simulator: 24 passed, exit 0, on
  the final code with the review fixes (23 passed on 7221cfe2 before them).
- Simulator, Messages, the keyboard's real draft code with the app's part
  played by the probe (it published the draft and the written text through
  `SharedStore`; no speech or model ran), on the final base (07b32b53, which
  lowercases a written text that continues a sentence): after
  `Hello team.`, `the build is green` went in underlined and became
  `The build is green.`; ` Noted` typed on the keys; `and i'll ship it
  tomorrow` went in underlined with "Writing…" on the strip and became
  `and I'll ship it tomorrow.`. The field read
  `Hello team. The build is green. Noted and I'll ship it tomorrow.` The
  written text is fitted to the text that was before the draft, so its
  casing is decided at the swap.
- Same setup, a key tapped while the draft was marked: the draft stayed and
  the key went in after it. Delete tapped instead: one character went.
- The dismissal and app-switch runs above. On the final code the Messages
  check and the Settings round trip were run again with the same results.
- `settleLeftDraft` has no unit test: `KeyboardModel` has no test harness,
  and the fake host would only test itself. It was checked in the Simulator.
- Seen twice and not explained: a draft the probe offered was not typed and
  nothing was logged, once at a load average above 150 and once at a normal
  load. The written text went in alone both times. A draft is typed only
  within 0.45 s of its creation (`Delivery.draftWindow`), which a late poll
  misses; three later tries with a diagnostic in place typed every draft.
- Not verified: a device; the real dictation (speech, the writer, the app's
  0.6 s wait); the keyboard's draft code in the Try it field (only the proxy
  calls were measured there); any other app; Send while the keyboard's own
  code holds a draft (measured with the probe's calls only); a written text
  that arrives in the seconds after another app was opened, before iOS told
  the keyboard (by the runs above the keyboard may log a swap that reached no
  field; the draft is then made plain on return, and the written text is
  in Paste last and History).
