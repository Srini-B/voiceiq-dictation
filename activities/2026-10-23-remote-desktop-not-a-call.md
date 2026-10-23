# Remote desktop sessions no longer offer to record a meeting

2026-10-23.

## Why

Connecting to the Mac mini with Jump Desktop showed "Meeting in Jump Desktop
Connect — record it?". No call was running.

## Cause

Jump Desktop's own log (`~/Library/Logs/Jump Desktop/Agent_*.log`) shows that
a per-session JumpConnect process starts capture on "Jump Desktop Audio" at
connect (`Starting capture for device: … Jump Desktop Audio`) and runs it
until disconnect, with client mic input on (`audioin:true`). It streams the
Mac's sound out and plays the client's mic into "Jump Desktop Microphone".
That is input and output running at once, so the generic two-way-audio rule
in `CallDetector` counted it as a call.

Both devices come from Jump's HAL drivers (`com.p5sys.jump.audio.driver`,
`com.p5sys.jump.audio.driver.mic`). The app is `com.p5sys.jump.connect`.

## Decision

A process whose audio goes only through devices its own developer's driver
provides is skipped (`CallDetector.routesOwnAudio`, `CallApps.vendor`). This
covers remote desktop hosts and audio routers in general, not only Jump. A
list of remote desktop apps was not added. A call app used during a remote
session still counts, because its developer differs from the driver's.

Rejected: telling direction per device. `kAudioProcessPropertyDevices` lists
a two-way virtual device under both scopes, so it cannot show that Jump
records one device and plays into the other. Rejected: device-owner lookup.
`kAudioObjectPropertyOwner` and `kAudioObjectPropertyCreator` return Core
Audio itself for these devices. The plug-in walk is the only source found.
It takes about 0.6 s, so it is cached until the device list changes.

## Verification

On the installed notarized 0.6.6 build, with scratch apps that do the same
audio as the Jump helper (record "Jump Desktop Audio", play a tone into
"Jump Desktop Microphone"):

- Before the change, `com.p5sys.jump.routersim` raised the offer.
- After it, the same app raised no offer.
- `dev.scratch.voipoverjump`, the same audio from another developer, still
  raised the offer.

Not tested: a real Jump Desktop connection, because it needs the user to
connect.
