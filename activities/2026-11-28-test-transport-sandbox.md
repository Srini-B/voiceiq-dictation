# 2026-11-28: Test suite stops writing into the real data folder

## Why

The 0.8.0 RC TextEdit check found 2 lines added to the real
`~/Library/Application Support/VoiceiQ/transport.jsonl` at 18:53:47Z. Both
were `cleanup` requests to 127.0.0.1 that got `http_400`, and they came from
a test-runner process. They were AssemblyAIClientTests: two of its tests send
a request to a local server that answers 400, and the client logs every
attempt under `FileLayout.appSupportRoot`. The class never set
`FileLayout.overrideRoot`, so every `swift test` run on a Mac wrote there.
That folder syncs to iCloud and must hold no test data. #164 fixed the same
problem in MeetingsEval.

## What changed

AssemblyAIClientTests uses a temporary data folder, set up the way
TransportTests does it. tearDown flushes the transport log before it clears
the override.

The 2 lines already in the real file stay there. They hold request metadata
only.

## Follow-ups (Fable 5.2 review)

- Make the sandbox the default under XCTest. `FileLayout.appSupportRoot`
  would return a per-process temporary folder when `XCTestCase` is loaded,
  so a test class that forgets its setUp cannot reach the real folder.
- TransportTests' tearDown should flush before it deletes its root.
- A test process follows the real app's debug-log switch and writes to
  ~/Library/Logs/VoiceiQ when that switch is on.

## Verification

CI's VoiceIQCore tests passed at 7a0c6b64: 374 tests, AssemblyAIClientTests
3 of 3. The Mac mini control run and the run with the fix are reported on the
PR.
