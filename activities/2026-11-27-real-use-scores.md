# 2026-11-27: D5 and C1 from real use; no paid eval credit

## Decision

- The Gemini eval key has no credit and will not be topped up. Testing cannot change Gemini, so the money goes to use, not evals.
- D5 and C1 of record now come from the owner's real use: `eval/realuse.py` reads the app's own History (key-up-to-text time per dictation) and usage ledger (tokens per call) on his Mac, read-only, at no cost. A thread runs it through the runner on his Mac when a release needs the numbers.
- Until a reading exists, D5 stays provisional at the pooled eval figures from before the credit ran out (main 38.6; 0.7.16 62.2), marked provisional, not a blocker.
- Prompt changes with no measured Gemini result stay parked and are not merged. Non-prompt fixes merge on CI and Neon (Neon bills Antigravity, not the eval key).
- Fable judges only packets that already exist.

## Verification

`realuse.py` was checked against a fixture database built to the app's schema (13 dictations including a failed one, one older than the window and one from the iPhone; 14 calls including an extra early request and a meeting): every printed figure matched values worked out by hand (₹1.074 per dictation, 1.1 calls per dictation, cache share 0.25, p50 5.5 s, meeting ₹29.6 per hour).
