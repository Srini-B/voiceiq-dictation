# 2026-11-28: Crash opening Settings › Advanced on a fresh Mac

## What happened

The redesign thread found that on a Mac with no agent access key, which is any fresh install, opening Settings › Advanced crashed VoiceiQ (EXC_BREAKPOINT, `_dispatch_assert_queue_fail`). By git history the crash has been in every release since 0.7.14. The release gates never caught it, because every test Mac already had a key.

## Cause

`AgentAccessSection.refreshStatuses()` reads the access key in a detached task. With no key, `AgentServer.accessKey()` creates one, and `KeychainStore.save` posts `.gtSettingDidChange` on that background thread. `NextMeetingModel` built its Combine chain in a `@MainActor` init, so its `.filter` and `.map` closures were main-actor isolated. They ran on the posting thread before `.receive(on: .main)`, and Swift 6's isolation check trapped.

## Fix (PR #169)

- Both notification publishers in `NextMeetingModel` move to main before any closure runs. No other subscriber on Mac or iPhone runs a main-actor closure before moving to main; Fable 5.2 checked every one.
- Test mode (`DebugDataFolder`) keeps VoiceiQ's Keychain keys under `io.blue.voiceiq.test:<path>`, so a test run in a new folder starts like a fresh install and can't read or change the owner's keys.

## Gates

- From 0.8.0 on, every release gets a fresh-keychain check: the signed build in test mode, with a new data folder, opens Settings › Advanced without crashing.
- Review: Fable 5.2 scored 90 at 7a8d029, with no High or Medium findings. Its Low findings are addressed in the follow-up commit.
- For later: `AppUpdater.start()` has the same shape (KVO `.map` closures before `.receive(on:)` in a `@MainActor` type). It's safe only while Sparkle changes those properties on the main thread.
