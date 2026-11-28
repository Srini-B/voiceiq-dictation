# 2026-11-28: Open review findings from the AssemblyAI move

## Why

Neon's review of #121 at 624cb3f (agy session 899750ba) left these open when
#121 merged. 0.7.18 ships from `release-0.7.18-gemini` without AssemblyAI, so
the AssemblyAI build becomes 0.7.19.

## What changed

- **Background dictations keep their note.** A dictation that finishes while a
  newer one owns the pill now reports the writer's fallback note ("Inserted
  as heard: …") through `DetachedResult.insertedWithNotice`. Before, the note
  was dropped and the text went in tidied with no word to the user.
- **Throttled polls wait as asked.** `AssemblyAIClient.transcribe` waits for a
  poll's 429 `Retry-After` (up to 30 s) before asking again, instead of
  polling on its own schedule. A job whose polls ran out of time while
  offline now fails as offline, so the recording queues for the reconnect
  instead of failing as a timeout.
- **`eval/realuse.py`** counts the writer's calls by stage (`cleanup`), not
  by a `gemini` model name, and prices `assemblyai/<model>` rows. Before, it
  reported 0 writer calls per dictation on AssemblyAI builds.
- **Release notes**: `release-notes/0.7.18.notice.md` became
  `0.7.19.notice.md`, with the Chrome extension removal line restored (the
  0.7.16 and 0.7.17 notices had it). Docs that named 0.7.18 as the AssemblyAI
  release now say 0.7.19; the on-device meeting removal stays 0.7.18.

## Verification

See the PR for `swift test` and the unsigned builds on lobsters-mac-mini.
