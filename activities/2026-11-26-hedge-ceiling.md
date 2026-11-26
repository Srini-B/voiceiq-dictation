# 2026-11-26: dictation backup request turned off

## Decision

The app no longer sends a backup request for a dictation. `DictationHedge.shared` is built with `sendsBackup: false`, so its delay outlasts every dictation's overall deadline and the second request never starts on a timer. The adaptive code stays in place. `DictationHedge(sendsBackup: true)` brings it back, with 0.7.16's limits: between 4 and 20 s, starting at 8 s.

Unchanged:

- A request that loses its connection still gets one more attempt at once (`GeminiClient.firstSuccess`). That is a rescue for a failed call, not an extra call on a working one.
- Send-on-pause (#97, about 4 extra billed calls per 100 dictations) stays.

`eval/dictation/run.py` now sends no backup request by default, to match. `--hedge-ceiling 6` or `20` reproduces the earlier commits.

## Why

No new Gemini calls were made for this. The eval key has no credit and won't be topped up, so the decision rests on runs collected earlier today.

- **The cleanest evidence is the dictation thread's 99 simultaneous request pairs (13:05 UTC).** A backup at 6 s gave the same p50 and p90 as a single request: 3.24 s and 9.04 s. The two copies' answer times correlate at 0.93. When the API is slow, both copies are slow.
- **The backup also adds calls.** On 26 Nov the backup fired on 22% of calls with #95's 6 s cap and on 15% with 0.7.16's 20 s ceiling. Both are over the cap of about 10% extra calls, which backups and send-on-pause requests share. At the ₹250 a month budget every call counts.
- **Pooled D5 cannot settle the ceiling.** It scored 62.2 for 0.7.16 and 38.6 for #95, but each build ran in different time slots, so the gap mixes the API's hour-to-hour load with the ceiling. The slot-by-slot differences were −47.0, −12.6 and +0.2, and #95 also changed the prompt. This PR first proposed going back to the 20 s ceiling on that evidence. That reading was dropped in favour of the paired-request result.
- **The per-call records confirm the backup did fire.** Every #95 call over 6 s sent its backup, yet single calls still took 46.6 s and 25.8 s.

## Open

- D5 for main with the backup off has not been measured; it needs eval credit.
- Until then, D5 of record stays provisional. The paired probe suggests latency matches a backup at 6 s.

## Verification

- `swift test --package-path VoiceIQCore` in CI. `testAppSendsNoBackupRequest` checks that the shared instance's delay outlasts a ten-minute dictation's deadline after a slow run. The adaptive test now runs on `DictationHedge(sendsBackup: true)`.
- `run.py` checked locally against a stub request, with no network: the default ceiling sends one request, and a 0.1 s delay sends two.
