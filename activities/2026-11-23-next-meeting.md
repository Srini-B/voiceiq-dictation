# Next meeting in Meetings and the menu bar

2026-11-23. Not released.

## Why

cyron, after the calendar integration in 0.7.13 (#64): with calendar access
given, show the next scheduled meeting in the Meetings section and in the
menu-bar menu. Mac and iPhone the same where possible.

## What changed

- `CalendarMeetings.next(after:)` finds the next meeting by the rules
  `event(at:)` already uses, up to a week ahead, with its start time and a
  Join link to Zoom, Google Meet, Teams or Webex when the invite has one.
  Nothing shows unless the calendar is connected in Settings and access is
  granted.
- Mac: a card above Record in Meetings (`NextMeetingCard`) and three items
  under the status line in the menu-bar menu, read each time it opens.
  cyron, on the first version: make the button "Join Zoom and Record", and
  put the card in the empty space above Record instead of pushing Record
  down. The card now sits in the titlebar strip (the sidebar ignores the top
  safe area while it shows), and Join starts a recording, then opens the link.
- iPhone and iPad: a "Next meeting" section above the record card in Notes
  (`NextMeetingSection`).
- The calendar permission text and the Settings copy on both say the next
  meeting is shown, since VoiceiQ now reads upcoming events too, not only
  the one being recorded.
- Recording starts only when the user presses Join and Record; nothing
  records on its own. Call detection still only offers to record. iPhone
  keeps Join alone: the phone cannot record calls.
- Test: `CalendarMeetingsTests` (Join link choice, minute countdown).

## Checked

On a Mac satellite (macOS 27, Xcode 27), Debug builds, with events added
through EventKit: the Mac card, the menu items and the iPhone 17 Pro
simulator section all show the seeded "Design review with Priya" with
"Join Zoom" (the invite's Google Docs link before it is skipped); the
iPhone countdown went from "in 13 min" to "in 7 min" without a relaunch;
with the calendar switched off, the card and the menu items are gone.
Join and Record, run through the menu item's action (synthetic clicks do not
reach the app on the satellite): the mic and system taps started, the new
meeting took the event's title, and Safari opened the Zoom link.
Not tried on a signed build or with a real Google or Exchange calendar.
