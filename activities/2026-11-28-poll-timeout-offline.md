# 2026-11-28: A timed-out poll no longer clears "offline"

## Why

Neon's review of #125 (agy, session c6ffac85): a transcript poll that timed
out set `offline = false`, though a timeout got no answer. When the network
stalls instead of failing fast (Wi-Fi with no upstream, slow DNS), the last
poll before the deadline could time out, clear `offline`, and the dictation
ended as failed (timed out) instead of queued for retry. A timed-out row is
still resent on reconnect (`HistoryStore.retryableRecords`), so the harm was
the "Timed out" error and earcon instead of "Queued", and retention: failed
rows can be purged, queued ones are kept. The same held for a DNS, connect or
TLS failure on a poll, which arrived as `.network` with the URLError's number.

## What changed

`AssemblyAIClient`'s poll loop: `.timeout` asks again and leaves `offline` as
it was; `.network` clears it only for an HTTP answer (`http_…`, not a
URLError number or `non-http`), as `MeetingEngine.waitsForService` tells them
apart.

## Verification

CI (`swift test`, App and iOS builds).
