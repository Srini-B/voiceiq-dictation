# 2026-11-28: A timed-out poll no longer clears "offline"

## Why

Neon's review of #125 (agy, session c6ffac85): a transcript poll that timed
out set `offline = false`, though a timeout got no answer. When the network
stalls instead of failing fast (Wi-Fi with no upstream, slow DNS), the last
poll before the deadline could time out, clear `offline`, and the dictation
ended as failed instead of queued for retry, so it was not sent again on
reconnect.

## What changed

`AssemblyAIClient`'s poll loop: `.timeout` asks again and leaves `offline` as
it was; `.network` (an answer arrived) still clears it.

## Verification

CI (`swift test`, App and iOS builds).
