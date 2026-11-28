# 2026-11-28: Mac setup asks for permissions on one checklist

## Why

The Mac setup asked for the microphone and for Accessibility on two separate
screens, and showed Screen Recording as a second card on the Accessibility
screen. People lost their place each time System Settings opened, and nothing
on screen said what to do inside the pane. The redesign asks for one
permissions step with live status and guidance, as the iPhone keyboard setup
already does.

## What changed

- The microphone and Accessibility screens are now one Permissions screen: a
  checklist card with a row each for Microphone, Accessibility (named as
  macOS names the list) and Screen Recording (optional).
- Each row goes Allow → Waiting… → ✓ Allowed. Grants are read twice a second
  while the screen is up and whenever VoiceiQ returns to the front.
- Opening a System Settings pane shows a small floating guide at the right
  edge of the screen with the step to take and an app icon that can be
  dragged into the list. It closes itself once the grant lands.
- The microphone level check moved under the Microphone row: it still says
  when no sound arrives from the selected input and offers the input picker.
- Continue needs the microphone and Accessibility. As before, the microphone
  can be left for later; Accessibility cannot.
- The onboarding window now uses the white canvas and muted subtitles of the
  redesign. Deep links `voiceiq://onboarding/<n>` now count 0 welcome,
  1 key, 2 permissions, 3 Globe key, 4 how to, 5 try it, 6 done.
- Input Monitoring is not asked for: VoiceiQ reads its keys through active
  event taps, which macOS covers under Accessibility.

## Checks

- Written in an environment without the Apple SDK; not compiled or run here.
  A build and a pass through setup on a signed build are still needed.
