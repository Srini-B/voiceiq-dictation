# iPhone: a dictation's text waits for its field

**2026-11-26.** Requested by cyron. He taps Dictate in the VoiceiQ keyboard,
then dismisses the keyboard, switches apps and scrolls to look things up
while he talks. The text could end up in the wrong place or only on the
clipboard. `docs/IOS.md` ("Where the text lands") describes the behaviour.
This entry records the decisions.

## What was wrong

The recording itself was not the weak part. The app records, and
`KeepAliveAudio` already keeps it running in the background. The delivery
was:

- The app waited 2 seconds for a keyboard, then put the text on the
  clipboard and marked it handled. A user who was still in another app got a
  clipboard copy, which replaced whatever they had gone to copy.
- Whichever VoiceiQ keyboard was on screen first typed the text, in any app
  and any field.
- A keyboard that came up while the app was dead mid-recording showed the
  idle mic, so the user had no way to learn the dictation needed the app.

## Decisions

1. **A result has a destination, and waits for it.** The destination is the
   field where Stop was tapped in a keyboard, or the field where Dictate was
   tapped when the stop came from outside a keyboard. The result stays
   pending for one hour. One function, `Delivery.route`, decides what a
   keyboard does with it, and `DeliveryRouteTests` covers it.
2. **No automatic clipboard copy when a destination exists.** The clipboard
   may hold what the user went to fetch. Copy is a button in the Live
   Activity, and Paste last types the text anywhere. A result that no
   keyboard took part in keeps the old 2 second clipboard path, because it
   has no field to wait for.
3. **A field is recognised by its app and its text.** The first design
   matched on `UITextDocumentProxy.documentIdentifier`. A probe in the
   iOS 27.2 Simulator showed that the identifier names an input session, not
   a text view. Field A reported `B850`, then `77B1` after hide and show,
   `12FF` after Field B had focus, and `DDE1` after an app switch. With that
   design every return would only have offered the text. Matching on the
   app alone was rejected, because it types into the wrong chat. The
   keyboard now compares the app and an FNV-1a fingerprint of the text around
   the cursor. The text itself stays out of the App Group.
4. **Two empty fields cannot be told apart, so the rule for them is a stated
   guess.** The first empty field of the destination's app that the keyboard
   is in after the text is ready receives it, for 10 minutes. The common case
   is one empty message field, and the guess makes that case work with no
   tap. The cost is a wrong field in an app with several empty fields. The
   text is typed, never sent, and the Undo dictation chip removes it. The
   10 minutes are an estimate of how long a lookup takes, not a measurement.
5. **The Live Activity is a control, not a keeper.** Sessions that the
   keyboard starts now show it (Settings › Dictation, on by default), with
   Cancel and Stop while recording and Copy while a result waits. Build 15
   showed that a Live Activity does not let the app start the microphone
   from the background, and nothing here depends on that.
6. **Not done: returning to the previous app through a private breadcrumb
   action.** `AppLauncher` already returns to the host. A second private path
   was not probed, so nothing about it is claimed.
7. **Not used: Apple's on-device models.** Nothing in delivery needs a model.
   The main path stays Gemini.

## Incident during the work

The first implementation read `textDocumentProxy.documentIdentifier` from
Swift on every poll. UIKit returns nil for it once the keyboard is dismissed,
the SDK declares it non-optional, and the Swift getter traps. The keyboard
extension crashed on every dismissal: 9 crash reports, SIGTRAP in
`KeyboardModel.documentID.getter`. iOS relaunched the extension, the new
instance typed the text, and two scenarios looked like passes. Those results
were withdrawn. The identifier is now read through key-value coding
(`TypingLogTraits.documentIdentifier`, the helper the Hex keyboard uses for
the same reason). Every scenario below also requires zero new crash reports
and the VoiceiQ keyboard on screen at each step.

## Verification

Mac satellite (macos-27, Xcode 27.2), this branch rebased on `origin/main`
`884208e`, which has the Hex QWERTY keyboard. The Mac mini runner was not used: the brief asked
for a satellite and no other threads.

- `swift test --package-path VoiceIQCore`: 268 tests, 0 failures.
- `xcodebuild build`, scheme VoiceIQ, unsigned: succeeded.
- `xcodebuild build`, scheme VoiceIQiOS, `generic/platform=iOS`, unsigned,
  as CI runs it: succeeded.

Scenarios in the iPhone 18 Pro Simulator (iOS 27.2) with a two-field scratch
host app, the simulated microphone and Gemini. Each step read the fields
from the accessibility tree.

| Scenario | Result | Keyboard log |
| --- | --- | --- |
| K2-a: keyboard dismissed while recording, and again before the text came | Pass, text in Field A | `first return to an empty field, waited 8s` |
| K2-b: switched to Settings and scrolled while recording, and left again before the text came | Pass, text in Field A | `first return to an empty field, waited 8s` |
| K2-c: scrolled the keyboard away while recording, and again before the text came | Pass, text in Field A | `first return to an empty field, waited 13s` |
| Stopped from the Live Activity with the keyboard dismissed | Pass, text in Field A | `first return to an empty field, waited 6s`, after `stopped from the Live Activity` in the session log |
| A field with text, returned to directly | Pass, text appended | `same draft, waited 13s` |
| A field with text, another field focused first | Pass, offered, typed only by Paste last | `result waits for …; offered in …` |
| App terminated while recording, reopened from the keyboard | Pass, text in Field A | `first return to an empty field, waited 3s`, after `recovered dictation waits for the keyboard` in the session log |
| Both fields empty, the other one focused first | Typed into the other field: the limit of decision 4, run on purpose | `first return to an empty field, waited 7s` |

A new dictation begun while the launch recovery still transcribed kept its
own result: the recovery finished 4 seconds after the new dictation began,
its text went to History only, and the keyboard typed the new result once.
The Codex review of the pull request found that the recovered text would
otherwise have replaced the newer result.

Copy in the Live Activity put the text on the Simulator clipboard and the
activity went back to "VoiceiQ ready".

Two caveats on the Simulator runs. The simulated microphone writes its audio
only at Stop, so the terminated-app scenario put an audio file into the
interrupted session's folder by hand. The real recorder writes while it
records. On an earlier build of this branch, one run of the Live Activity
scenario had a 57 second Gemini call. The keyboard typed the text in the same
second it was ready.

## What only an iPhone can prove

- The microphone keeps recording across an app switch and a long lookup.
  The Simulator has no real microphone, no jetsam and no memory pressure.
- Stop, Cancel and Copy from the Dynamic Island. The Simulator run used the
  same activity in Notification Centre.
- Copy from a locked phone: iOS may refuse a clipboard write from the
  background.
- `documentIdentifier` and the text reads behave on a device and in real
  apps (Messages, WhatsApp, Safari) as they did in the scratch host. An app
  that reports no text around the cursor for a field with text would get the
  empty-field rule.
- `AppLauncher` returning to the host, which was already device-unverified.
- Recovery after iOS itself ends the app.

## Rollback

Revert the commits. An older build reads a new snapshot without error: it
ignores `destination`, and types the last result under its old rule. A new
build reads an old snapshot as a result with no destination.
