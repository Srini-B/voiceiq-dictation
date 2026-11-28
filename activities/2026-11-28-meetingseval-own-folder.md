# 2026-11-28: MeetingsEval stops writing into the app's data folder

## Why

During the 0.7.19 RC TextEdit check, `transport.jsonl` in the real
`~/Library/Application Support/VoiceiQ` grew by 9 lines. All 9 were
`meetingSummary` requests from another thread's MeetingsEval run. MeetingsEval
built the app's AssemblyAI client, and the client's `TransportLog` writes next
to the history database. The speaker model download went into the same folder.
The release owner's rule is that the real data folder holds no test data, and
that folder syncs to iCloud. A command-line tool also cannot read the app's
`DebugDataFolder` test-mode key, because it has its own defaults domain.

## What changed

MeetingsEval sets `FileLayout.overrideRoot` to
`~/Library/Application Support/VoiceiQ-MeetingsEval` before it makes any
request. Its request log and the speaker model now live there. Its usage
database and meeting folders were already temporary. The first run after this
change downloads the speaker model again (21.6 MB). `eval/meetings/README.md`
says where the files go.

LocalMeetingsEval makes no AssemblyAI request, so it writes no request log. It
still keeps its models in the app's model folder.

## Verification

See the PR for the MeetingsEval build and a short run on lobsters-mac-mini,
with the real folder's `transport.jsonl` unchanged.
