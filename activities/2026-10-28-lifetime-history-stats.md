# 2026-10-28: History stats count every dictation, with a period picker

## Why

The owner asked that the stats above History (words, dictations, WPM, audio,
saved, streak) be lifetime figures that survive deleting or clearing History,
and that a period such as a week or a month can be picked. Before this, the
stats were summed from the History rows, so every deletion, Delete All
History and transcript retention lowered them.

## Decisions

- A separate `dictationStat` table holds the counts per dictation (day,
  words, audio seconds) and no text. Keeping deleted History rows with a
  hidden flag was rejected, because clearing History must remove the
  transcripts.
- The table is keyed by dictation id and written with the dictation row, so a
  Retry replaces the count instead of adding one, and a dictation synced from
  the other device counts once on each device.
- Migration `v4-stats` backfills from the History that exists, so dictations
  deleted before this change are not recovered.
- Periods are rolling: today, last 7 days, last 30 days, last 12 months, all
  time. Streaks and active days stay all-time, because a week window would cap
  a streak at 7.
- The Mac History pane keeps its sidebar after History is cleared, so the
  stats stay visible. The choice of period is remembered. The iPhone Home
  stats show all time and have no picker.

## Verification

- `scripts/test.sh`: 145 tests pass.
- Scratch tests (deleted afterwards) checked: totals for each period;
  a Retry replacing a count; no change after `deleteFromCloud`, `deleteAll`
  and `forgetCloud`; and a v3 database backfilled by the migration.
- Signed and notarized Release build installed and checked in the History pane.
