# Dictation step times in History

## Why

On 0.7.9 with Scribe v3 Live on and screen context off, dictations on the user's MacBook took 2.9–4.5 s from key-up to text. History showed only the total.

## Findings (4 dictations on 0.7.9, from the debug log)

| Audio | Finish recording | Live final | Writing call (first byte) | Insert | Key-up to done |
| --- | --- | --- | --- | --- | --- |
| 28.1 s | 476 ms | 344 ms | 3,494 ms (3,205) | 198 ms | 4,519 ms |
| 30.0 s | 102 ms | 343 ms | 3,553 ms (3,465) | 145 ms | 4,149 ms |
| 19.5 s | 95 ms | 344 ms | 2,339 ms (2,262) | 148 ms | 2,933 ms |
| 44.9 s | 89 ms | 362 ms | 2,673 ms (2,582) | 152 ms | 3,287 ms |

- The live stream worked every time, with no fallback.
- What separates the fast dictations from the slow ones is the writing call's time to first byte. Length, output tokens, connection and retries do not differ.
- Every writing call reported 0 cached tokens. From an orb, the same prompt stayed cached across 2-minute gaps, with or without `prompt_cache_key`. The cause is not known yet.
- The user does not want a faster writing model or OpenAI Fast mode. Remaining levers are outside the writing call: start it at key-up on Scribe's last partial text (about 0.3 s; the partial equalled the committed text in 6 of 6 test streams) and skip the AX insert attempt that falls back to ⌘V every time in Amp (about 0.1 s).

## Change

History shows each step under Pipeline on the Mac and iPhone: finish recording, transcription (live or upload), writing model and insert. The pipeline now starts at key-up, so the steps add up to it. Verified on the Mac mini: 185 VoiceIQCore tests pass, and the Mac and iOS builds succeed. Screenshots were rendered from isolated copies.
