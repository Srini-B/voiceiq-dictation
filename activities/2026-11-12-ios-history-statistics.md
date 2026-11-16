# 2026-11-12: Dictation statistics on iPhone

## Why

The owner asked for the Mac History's statistics on the iPhone. Until now the
iPhone showed only four all-time tiles on Home (words, dictations, WPM,
audio), with no period, time saved or streak.

## Decisions

- No new core code: the page reads `HistoryStore.stats(period:)` and
  `StatsPeriod`, the same calls the Mac History pane uses, and remembers the
  period under the same `historyStatsPeriod` key.
- A page of its own (`StatsView`) rather than a header above the list,
  because six tiles above the day list push the dictations off an iPhone
  screen. It opens from a Statistics row at the top of History (the row
  stays when History is cleared, since stats outlive it, and hides while
  searching) and from Home's stats grid and its "See all".
- The Mac shows the longest streak and active days in a hover tooltip; the
  iPhone has no hover, so they are a line under the tiles, with a note that
  deleted dictations still count and that time saved assumes typing at
  40 words per minute.
- Home keeps its all-time grid; its tile view moved to `StatTile` and is
  shared with the new page.

## Verification

- Not yet built: no Apple build was run for this change. Simulator screenshots of
  Statistics (each period, an empty History with stats, iPad split view)
  are still needed.
