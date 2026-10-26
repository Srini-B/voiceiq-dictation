# 2026-10-26: Downloaded updates restart on their own

Follows `2026-09-29-release-automation-and-update-pill.md`.

## Request

After an automatic download, the pill showed "VoiceiQ x.y.z is ready" with a
Restart button. The owner asked for the restart to happen automatically
instead of waiting for a click.

## Decisions

- A downloaded update now installs and relaunches as soon as nothing is in
  use. "In use" is unchanged (dictation, Ask Anything, Translate, a meeting
  detected, recording or being written up, an answer on screen). While the app
  is in use, it checks again every 30 seconds.
- Removed the 5-minute no-input condition. It kept the update waiting while
  the user typed in other apps, and the relaunch takes a few seconds and
  interrupts nothing in VoiceiQ.
- Removed the "is ready" pill (`PillState.updateReady`, `UpdateReadyContent`,
  its Restart and × notifications). It would only show for the moment before
  the relaunch. The status menu still says "Restart to Install VoiceiQ x.y.z"
  while the app is in use, and quitting still installs.
- The first install attempt now runs on the next main-actor turn. `@Published`
  sinks fire before the value is stored, so the old synchronous check saw the
  previous value and the install waited for the 30-second timer.
- "Updated to VoiceiQ x.y.z" after the relaunch is unchanged.
