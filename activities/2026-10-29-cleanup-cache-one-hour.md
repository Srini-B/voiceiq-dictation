# 2026-10-29: One-hour cache for cleanup rules, cache writes booked at their price

## Why

The owner asked whether the cleanup cache helps at all, since dictations are
minutes apart and their text differs. The cached part is the rules block up to
`PromptV1.layoutReminder` (12,659 tokens on the owner's MacBook), not the
dictation, so it is shared by every dictation until the Dictionary or writing
rules change.

The MacBook's four Claude cleanups that afternoon hit 2 of 4 with the
five-minute cache. In the History list for the day (1:25, 1:26, 1:29, 1:48,
2:42, 2:55, 3:39, 5:40, 5:41 PM), 3 of 9 would hit with five minutes and 7 of 9
with one hour. A one-hour write costs 2× input against 1.25×, so it pays once
about half of dictations land within the hour.

## The 5:45 PM miss

It came 4 minutes after a cache write, so it should have hit. All four requests
carried screenshots (180–197 KB in `transport.jsonl`), so the screen-context
section was the same. The MacBook's Dictionary shows "DeepInfra" auto-learned at
5:42:19 PM. New words go first in the vocabulary, which is inside the cached
block, so the next dictation wrote the block again. Expected behavior: each
learned word costs one write. Moving the vocabulary after the breakpoint would
send about 500 uncached tokens with every dictation instead, which costs more.

## What changed

- `GeminiClient.anthropicCleanupSplit` marks the rules block with
  `AgentCachePolicy.staticTTL` (`ttl: "1h"`).
- `TokenUsage.fromAnthropic` reads `usage.cache_creation` into `cacheWrite5m`
  and `cacheWrite1h`. `ModelPrice.cost` adds 0.25× input for a five-minute
  write and 1× for a one-hour write. Before, writes were booked at plain input.

## Verification

- Live probe on Haiku 5.5 with a one-hour `cache_control`: the first call
  reported `ephemeral_1h_input_tokens: 16811`, the second
  `cache_read_input_tokens: 16811`.
- A scratch test fed that response to `fromAnthropic` and got
  (22 × 0.10 + 16,811 × 0.20 + 16 × 0.50) / 1M from the price book, and checked
  that the cleanup split sends `ttl: "1h"`. Deleted afterwards.
- `swift test`: 143 tests pass.
