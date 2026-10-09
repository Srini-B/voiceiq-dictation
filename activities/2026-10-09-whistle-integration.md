# Optional Whistle transcription

2026-10-09. The user approved Whistle only on the OS versions supported by the
published native binaries, with runtime detection before enablement.

Added an off-by-default setting for Apple Silicon macOS 26+ and iOS/iPadOS 27+.
The app retains deployment targets macOS 14 and iOS 17. A dynamic framework
loads only after the availability check. Static linking would impose the
vendor's newer minimum OS on every launch, including cloud-only users.

The shared dictation factory selects Whistle ahead of cloud real-time when
enabled. Meetings do not use that factory. Saved audio remains authoritative;
incomplete local results use the existing batch fallback. Cleanup, transforms,
and available screenshots retain the selected provider and key. No live text
was added to the pill. Cloud real-time and Smart transcription settings remain
saved while their controls are disabled.

Needle was not integrated. Its structured tool-call output and lack of image
input do not satisfy the existing writing rules. Local command routing remains
a possible separate use, not a requirement of this change.

## Verification

- Existing VoiceIQCore suite passed, 143 tests, zero failures. No permanent tests
  were added.
- `scripts/release.sh` produced a signed, notarized, stapled macOS app and DMG.
  Installed the app on the Mac mini and checked its signature and Gatekeeper
  acceptance. No Debug macOS app was tested.
- Installed-app synthetic speech produced a `whistle-local` call at zero cost
  followed by Gemini cleanup with image input, with no batch transcription call
  in that session. Raw text contained recognition errors; the final text was
  "Send the revised report to Priya by Friday." This is a functional check,
  not a recognition-accuracy or latency benchmark.
- `scripts/build-ios.sh` passed after correcting Bash 3's empty-array expansion
  in the embed script. iPhone and iPad simulator settings rendered and changed
  the Whistle toggle. Accessibility state confirmed cloud real-time and Smart
  transcription were disabled while local transcription was on. Screenshots
  were inspected in `.amp/in/artifacts/whistle-settings/`.
- The macOS app and iOS simulator executable retain minimum OS 14 and 17.
  `otool` found no startup link to Whistle. The embedded native binaries retain
  their vendor minimums, macOS 26 and iOS 27.
- Physical iPhone/iPad execution, App Store validation, and actual launch on
  older OS versions remain unverified. The earlier native probes are recorded
  in `2026-10-09-whistle-evaluation.md`. No broad accuracy or speed claim follows
  from these smoke checks. Forced ring overflow and native inference failure
  were not exercised end to end in the installed app.

## Delivery and rollback

These changes are local and uncommitted. Nothing was pushed, published, or
uploaded to TestFlight. To stop using local transcription, turn off Whistle in
Settings → Dictation. This restores the saved cloud preferences.
The pre-verification Mac mini app is backed up under `.amp/in/pre-whistle-VoiceiQ.app`.

Later on 2026-10-09, the user requested installation on the MacBook. Transferred
the notarized 0.5.17 ZIP, compared its SHA-256, and installed it at
`/Applications/VoiceiQ.app`. The installed executable hash matches the verified
Mac mini release. Deep signature verification and stapled-ticket validation
passed. Settings and credentials were not changed. The previous app is at
`~/.local/state/cross-device/jobs/voiceiq-whistle-20261009/previous-VoiceiQ.app`
on the MacBook. Automatic relaunch was blocked by pending Cua Driver screen
recording permission; the user must open VoiceiQ normally. No new MacBook
runtime or UI verification is claimed.

## MacBook insertion report

The user reported a green tick with 85 words but no paste. Read-only inspection
matched that count to the 09:00 IST session on October 9. Whistle and Gemini
cleanup succeeded; both SQLite and `meta.json` recorded `inserted`, with VoiceiQ
itself as the destination. The cleaned transcript remains saved. The latest
`bad_request` failure was from October 8 at 21:04 IST, before this installation.
History pins failed rows above the transcript timeline, which can make that
older failure look like the latest result.

The insertion fallback treats posting synthetic Command-V as success without
a delivery receipt. This can explain the green tick without a paste, but the
original focused field and actual insertion tier are not recoverable from the
retained logs. No insertion code was changed based on that inference. Retried
Cua Driver launch and the native permission-grant flow; Screen Recording remains
pending, so interactive reproduction on the MacBook is blocked.

The user then confirmed that no target window had focus and a second dictation
worked. Closed the insertion investigation without changing that code.

## Short dictations skip cleanup

The user requested raw transcription for short recordings and cleanup only
above 10 seconds. Added the duration to the shared post-transcription API so
Whistle, cloud real-time, and batch dictation follow the same rule. Exactly
10 seconds skips cleanup. Existing local dictionary replacements remain active.
Ask Anything, Translate, and Agent keep their requested actions. History records
the reason for skipping writing rules without identifying a writing model call
that did not occur. Transcription-stage Smart mode is unchanged.

A disposable probe exercised the real service against a loopback HTTP responder.
Recordings of 0.5, 9.999, and 10 seconds retained raw filler words and skipped
cleanup. A 10.001-second recording received the responder's cleaned text.
With writing rules off, 30 seconds still skipped cleanup. Two-second Ask Anything
and Translate requests still called the responder; Agent returned its command.
The responder recorded exactly three requests. Removed the probe and responder
afterward. All 143 existing tests and the iOS simulator build passed.

This duration rule remains a local code change. It has not been included in a
new signed/notarized macOS build or installed on either Mac. No commit or push
was made.

## Follow-up: five-second cutoff and window focus

The user lowered the cutoff to five seconds and reported that closing the main
window sometimes leaves no external window focused. Reused the existing
previous-frontmost-app tracker for an explicit handoff after the main window
closes. The handoff runs only while VoiceiQ is active and has no visible
main-capable window. It does not take focus away from another active app.

The original stranded-focus state did not reproduce on the Mac mini with the
previous installed notarized build. On the new installed signed/notarized
release, Cmd-W and the close button both closed the main window and returned
focus to Chrome. Reopening worked. Closing the VoiceiQ window in the background
left Safari frontmost. These checks used accessibility and frontmost-app state;
they do not establish that every MacBook focus failure is resolved.

A disposable service probe checked 0.5, 4.999, and 5 seconds without cleanup,
and 5.001, 8, and 10 seconds with cleanup. The loopback responder saw exactly
three writing requests. Removed the probe afterward. All 143 existing tests,
the iOS simulator build, and `git diff --check` passed.

`scripts/release.sh` produced the signed/notarized 0.5.17 application and DMG.
Installed and verified this build on the Mac mini with codesign and Gatekeeper.
The prior installed app is retained at `.amp/in/pre-focus-five-VoiceiQ.app` for
rollback; quit VoiceiQ before replacing the installed app with that copy.
This follow-up has not been installed on the MacBook, committed, pushed, or
published.

## Follow-up: optional short-dictation cleanup rule

After installing the focus/cutoff build on the MacBook, the user reported that
there was no toggle for the five-second rule. Added "Skip cleanup for dictations
of 5 seconds or less" below "Apply writing rules" on macOS and iOS/iPadOS.
The preference defaults to on to preserve the requested fast path. Turning it
off allows short dictations to use cleanup; turning off writing rules still
disables cleanup regardless of duration. Other dictation modes are unchanged.

All 143 existing tests and the iOS simulator build passed. A disposable service
probe verified default-on, persisted on/off values, routing at 0.5, 5, and 5.001
seconds in both states, and the writing-rules master switch. Missing API keys
deliberately exercised cleanup's auth fallback without paid requests. Removed
the probe after verification.

Built with `scripts/release.sh` and installed the signed/notarized release on
the Mac mini. Inspected screenshots of the toggle on and off, verified its
saved value, and restored it to on. The iPhone simulator accessibility tree
contained the new switch, but mobile visual inspection remains incomplete.

Installed the corrected signed/notarized 0.5.17 build on the MacBook. Archive
and executable checksums matched the Mini; codesign and stapled ticket checks
passed. Preserved its prior app under
`~/.local/state/cross-device/jobs/voiceiq-short-toggle-20261009/previous-VoiceiQ.app`.
The user must quit and reopen the running app to load this replacement.
No commit, push, or public release was made.
