# 2026-11-28: The iPhone draft in more apps

## Why

The iPhone keyboard's draft swap (`activities/2026-11-28-iphone-draft-swap-by-insert.md`,
PR #160) was on only in Messages. It was widened to every app where it was
measured safe, and three Low findings from that PR's review were fixed.

## What was measured

iOS 27.0 Simulator, iPhone 17 Pro, a fresh device with no Apple ID. A debug
probe (never committed) published a draft and then the written text through
`SharedStore`, so the keyboard's real draft code ran in each host. The host's
text was read as its accessibility value (a local page reported its own value
in Safari; Calendar's notes field by screenshot). Scenarios: earlier text
before the draft; dictation, typed " Noted", dictation; two dictations back to
back, also with the second offered while the first's written text was pending;
a letter and Delete while the draft was marked; a 300-character draft; Tamil
with an emoji.

| Host | Bundle ID | Result |
| --- | --- | --- |
| Messages (control) | com.apple.MobileSMS | every scenario exact |
| Reminders | com.apple.reminders | every scenario exact |
| Contacts, notes | com.apple.MobileAddressBook | every scenario exact |
| Calendar, event notes | com.apple.mobilecal | every scenario exact |
| Safari, plain textarea | com.apple.mobilesafari | every scenario exact |
| Safari, contenteditable | com.apple.mobilesafari | every scenario exact |
| Safari, textarea whose script sets its value on every input | com.apple.mobilesafari | every dictation twice |

In the scripted field WebKit starts a composition for the marked draft; the
script's value write ends it without telling the keyboard, so the swap's insert
lands beside the now plain draft. A keyboard sees one bundle ID for every page
field, so Safari stays off, and so does every other browser (they use the same
WebKit fields).

Notes, Mail, Freeform and Journal are stubs without an executable in the iOS
27.0 Simulator runtime and do not launch. With no App Store in the Simulator,
WhatsApp, Slack, Chrome and Gmail cannot be installed. These stay off until a
device run.

Also seen: a second draft offered while the first is still held goes stale
and its written text goes in alone (no loss); the letter typed while a draft
is marked mid-sentence comes out capitalised, since the shift state does not
count the marked draft.

## What changed

- `Delivery.draftHosts` (bridge, shared by app and keyboard) replaces
  `KeyboardDraft.verifiedHosts`: Messages, Reminders, Contacts, Calendar. The
  app offers a draft, and waits up to 0.6 s for it, only for a destination in
  one of these, so elsewhere the written text is not held back.
- A key, Delete, cursor move, Paste last or Undo in the run loop turn of a
  `setMarkedText` or `unmarkText` runs on the next turn
  (`EditController.runsNow`, `KeyboardModel.markedTextThisTurn`), and so
  does a result or Paste last (a result waits for the next poll). The keys read the text before the cursor
  with the waiting edits in it (`EditController.projected`), so a word-wise
  Delete swipe takes the right words. Checked on the fake host only.
- Mac: a ⌘V draft the field never showed is `DraftShown.unseen`; the pill
  says "Couldn't see the text land. Paste last has it", not "Kept as heard".

## Verification

Mac mini, iOS 27 Simulator, and CI: `swift test --package-path VoiceIQCore`,
both schemes built unsigned, and KeyboardTests (counts in PR #171). Contacts
and Calendar were measured in their notes fields; their other prose fields
(titles, search) get drafts by the same bundle ID unmeasured. Messages rechecked on the branch with the probe. No real device was
used.
