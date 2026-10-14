# 2026-10-14: Retried dictations re-sync; CodeRabbit fixes from PR #10

## Why

CodeRabbit's review of PR #10 (released as 0.6.1) found that Retry on a
dictation already in iCloud never reached the other device. Retry is
offered on finished rows on both apps. `HistoryStore.upsert` kept
`cloudSyncedAt`, so the new text was never uploaded. Even with that cleared,
the upload builds a new `CKRecord` without the server's change tag, and the
`serverRecordChanged` failure was counted as synced. The review also found
two minor issues, both confirmed in the code.

## What changed

- `HistoryStore.upsert` keeps `cloudSyncedAt` only while the row's
  `displayText` and `status` are unchanged. A Retry that changes them makes
  the row an upload again.
- `HistoryStore.applyFromCloud` replaces the text of another device's row.
  For this device's own row it records `cloudSyncedAt` only when the server
  copy matches, so an older copy does not cancel a pending re-upload.
- `HistorySync`: on `serverRecordChanged`, when the server copy differs from
  the row, the engine keeps that copy, which carries the change tag. It
  re-adds the save and sends it from a detached task. The next batch sets
  our fields on the server copy. The engine did not resend a failed save on
  its own: nothing was sent within 4 minutes. A plain `Task` crashed the
  app: CloudKit traps "Cannot await a call into CKSyncEngine from within a
  delegate callback" (crash report 2026-10-14-102613), because the task
  inherits the callback. `Task.detached` does not.
- `PromptV1.sanitizeLine` also replaces `\r`, so a window or page title
  cannot start a new prompt line.
- `docs/design/architecture.md`: `.translate(targets:)`, Ask Anything
  replacing a writable selection, and the three-target
  `translationTargetLanguages` setting. `docs/IOS.md` describes the new sync
  rule.

## Verification

- A scratch XCTest (deleted) covered four cases: unchanged text stays
  synced, changed text uploads again, an older server copy does not mark the
  row synced, and another device's row takes the new text. All four passed
  with the fix. With the old `upsert` and `applyFromCloud`, three failed;
  the unchanged-text case passed both ways, as it should.
- Live, on a notarized build installed on the Mac mini, against the
  Production container. In the folder of a synced row (`DC4A0F3F`), the
  `meta.json` text was edited, and the launch reindex upserted it. The log
  showed "1 changed row(s), sending again over the server copy", then "sent
  1 row(s)" one second later. The row was marked synced. Restoring the
  original text ran the same path back: the fetch returned the edited
  server copy and the row stayed pending, then the resend succeeded. Zero
  rows were left pending, and no crash report followed.
- `scripts/release.sh`: 143 tests pass, notarization Accepted.

## Not verified

- A second device receiving the changed text. `applyFromCloud` is covered
  by the scratch test only.
