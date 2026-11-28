# Upstream watch run (2026-11-28)

New baselines: Hex `6e50ad92` (reviewed from `f1c772c9`; `012bdbbe..f1c772c9`
was covered on 2026-11-27) and FluidVoice `413fafde` (from `ffa6639e`). The
web sources are now listed in `docs/upstream-watch.md`. Nothing was built in
this run, and no Gemini call was made.

## Passed to their owners

- **"Who spoke when in meetings":**
  - Hex `0926dd92`: the first call-app adapter reads a Slack huddle's tiles and the person Slack marks as speaking, to name remote speakers. Hex's tests read hand-written trees and did not observe a live huddle.
  - Hex `f21415bd`: the call-window walk now guards against cycles and shell roots.
  - Hex `566c99fc`: a recording is matched to the calendar event whose call link names the call's own service, and an ambiguous overlap matches nothing. VoiceiQ's `CalendarMeetings.event(at:)` takes the event that started nearest, so it can pick the wrong one of two overlapping events.
  - Hex `2a70e582`: autorelease pools are drained between capture polls after a reported out-of-memory crash. VoiceiQ's `ScreenNameSampler` polls Accessibility and screen captures in a detached task. Whether its pool drains on each tick was not checked.
- **Closed owner threads, so these go in the report instead:**
  - Rule cleanup ("Drop on-device writer, add rule cleanup", archived): Hex `a0f0a858` adds the guard that decides which spoken words may be removed. Hex `f9740384` adds a Lab, off by default, that uses a 26 MB on-device disfluency tagger behind that guard. Hex `e2772679` extends the guard. Its release-tail half is out of scope by cyron's rule.
  - iPhone keyboard ("Hex QWERTY keyboard for iPhone", archived): Hex `f5819f4c` rebuilds `en.hextm` with names, days and places ("Claude", "Monday", "London"), capitalises corrections to them, and drops the extra 4-nat cost for English names in swipe. VoiceiQ ships the old model and still has `nameCost = 4.0` in `SwipeTyping.swift`, so these words cannot be swiped. Size M: a 3.6 MB model swap plus small Swift changes.

## Skipped

- Hex `773770138`: retired event taps are now invalidated, and a stuck tap is rebuilt with backoff. VoiceiQ's `EventTapEngine` already invalidates its tap and never rebuilds one in a loop. `GlobalShortcutEngine.stop()` disables its tap and stops its run loop without invalidating the tap. Normally the thread then exits and the tap goes with it. A `stop()` that lands before `CFRunLoopRun()` starts leaves a disabled tap on a thread that keeps running (`EventTapEngine` avoids this by running its loop in slices). That costs a thread, not keys, so it was not built.
- Hex `6e50ad92` (one meetings setup screen), `54342fa2` and `8d5ed673` (meetings layout), `2f8c3b70` (sheet sizing): Hex's UI; VoiceiQ keeps its own.
- Hex `06a63b35` (stale `local-api.json`): VoiceiQ writes no discovery file.
- Hex `b3395ed8` (No final period keeps ? and !) and `7a38981d` (Paste Last picker): VoiceiQ has neither feature.
- Hex Windows, Linux, Android, Annotate and site commits: out of scope.
- FluidVoice `9746322c` (Markdown notes on meetings): VoiceiQ has had this since #114. `19a6cc29` (file library with speaker names) and `413fafde` (Command Mode sees the screen): no matching VoiceiQ feature, and an AI command mode is out by cyron's earlier rule.
- Web:
  - Superwhisper meeting summaries in the transcript's language, and resuming a finished meeting, were noted for the meetings thread; changing the Gemini prompt needs approval.
  - Wispr Flow Canto-2 and Aqua's Avalon 1.5 are their own speech models, with nothing to adapt.
  - Aqua's "Add to Claude" listing: VoiceiQ already sets agents up itself.
