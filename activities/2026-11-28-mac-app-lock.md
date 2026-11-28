# 2026-11-28: A lock for the installed app on the Mac mini

Agents on lobsters-mac-mini quit and reinstalled `/Applications/VoiceiQ.app` under each other. It broke the live-call probe twice (18:32 and 19:35 IST). The 18:32 quit was first logged as "⌘Esc quit the app mid-dictation, cause unknown".

## The ⌘Esc quit

- The unified log for pid 34452 shows `osascript[35002] AESendMessage(aevt,quit target=[VoiceiQ])` at 18:32:42.032 IST, then `RECEIVED:(aevt,quit)`, AppKit's `Handling Quit AppleEvent`, and the normal `prepareForTermination`. There's no VoiceiQ crash report after Nov 22.
- pid 35002 belonged to the live-call probe thread, which runs `quit app id "io.blue.voiceiq"` before a clean run. The ⌘Esc came 13 s later.
- On a notarized 0.7.17 (92) build, ⌘Esc during a hands-free or a held-fn dictation logged `state → cancelled`, and the app stayed up. Idle, it did nothing. No menu item uses ⌘Esc.

## The rule

- Before quitting, installing or replacing the app, take the lock: `scripts/app-lock.sh acquire <thread ID>`. It makes `/Users/lobster/.voiceiq-app.lock` and writes the owner and time into it. Release it when done.
- A lock under 30 minutes old means wait; an older one is stale and can be taken.
- Tests that don't need the real install use their own copy, such as `~/Applications/VoiceiQ-<thread>.app`.
- `eval/live-call/run.sh` holds the lock for its run (`LOCK_OWNER`). AGENTS.md carries the rule.

## The queue

The iPhone draft-swap check that gates 0.7.19 waited more than 30 minutes behind other jobs, with load at 100–900 and 2–3 simulators booted. Heavy jobs now take a turn through `scripts/mac-queue.sh`, using tickets in `/Users/lobster/.mac-mini-queue`:

- `wait <thread ID> <class> "<what>"` joins and returns at your turn; `done <thread ID>` leaves; `show` lists the queue.
- **Classes, in order:** `release` (gates the next release), `merge` (gates a PR), `other`. First come, first served within a class.
- **Two slots.** A started job keeps its slot until `done`, so a later release job waits for a slot rather than pushing past the cap.
- **Stale tickets** older than 3 hours are dropped. A longer job runs `wait` again to refresh its ticket.

Tested on Linux with a 1 s poll: two running jobs, then a third (`other`) and a fourth (`release`, arriving later). The release job started first when a slot opened, and never more than two ran at once.

The app lock's stale-lock takeover and its release both go through one mutex, so neither can delete a fresh lock another owner just took (Codex found both races). Race tests: 6 contenders on one stale lock, 30/30 rounds with exactly one winner; a release racing a takeover, 40/40 rounds with the new owner keeping its lock.
