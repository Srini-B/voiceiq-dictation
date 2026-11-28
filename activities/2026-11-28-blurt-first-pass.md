# Upstream watch: Blurt first pass (2026-11-28)

## Why

cyron added [AssemblyAI/blurt](https://github.com/AssemblyAI/blurt), AssemblyAI's
own Mac dictation app, to the two-day upstream watch: VoiceiQ uses
AssemblyAI too. Baseline `264d0ccb` (2026-11-28). Licence: MIT (Copyright
(c) 2026 Alex Kroman), so code may be adapted with credit.

## What Blurt does, against VoiceiQ (#121)

- **Dictation** goes to AssemblyAI's separate Dictation API
  (`dictation.assemblyai.com/v1/transcribe/live`): one chunked multipart
  request uploaded while you speak, with the cleanup rewrite run on the
  server. VoiceiQ streams to STT-3.7 Realtime and writes with GPT-6 Luna on
  the LLM Gateway; #121 turned the Dictation API down for its price, its
  older model and its three small writer models. Blurt uses streaming only
  for meetings, and sends no turn-detection or keyterm parameters there.
- **Keyterms and prompts:** Blurt sends a comma list as `keyterms_prompt`
  (2,048 bytes, 100 terms) and the text before the cursor plus recent
  dictations as `stt_prompt`. VoiceiQ
  sends no keyterms on purpose (names 77.9 with them, 95.7 without) and no
  STT prompt.
- **Turn detection:** both end on key-up. Nothing to take.
- **Writer:** Blurt's server-side instruction forbids answering or adding
  words, like PromptV1; it pastes the verbatim text when the rewrite fails,
  and rejects a rewrite that echoes its own instruction (`RewriteGrounding`).
  VoiceiQ's writer has a retry, structured output and the tidied fallback;
  it has no echo check.
- **Latency:** Blurt warms the Dictation host at key-down and
  uploads while recording. VoiceiQ already streams while recording; its
  writer call pays a fresh TCP and TLS handshake (30–150 ms) on purpose,
  because idle QUIC connections reset.
- **Errors:** VoiceiQ keeps the audio, retries and queues offline, which
  Blurt cannot. Blurt's key check rejects a key only on 400, 401, 403 or
  422; VoiceiQ rejected it on any status but 200, 429 and 5xx, so a moved
  endpoint or a captive portal blocked onboarding with a good key.

## Built (branch `blurt-first-pass`)

- Key check: only 400, 401, 403 and 422 reject a key; anything else is
  unreachable and lets onboarding continue (`AssemblyAIClient.keyCheck`).
- User-Agent `VoiceiQ/<version> (macOS|iOS x.y[; dev])` on every AssemblyAI
  request and the realtime socket (`docs/PRIVACY.md` updated).
- Logs carry the realtime session ID and the pre-recorded transcript ID,
  which AssemblyAI support can look up.

## Sent to the AssemblyAI owner (T-51b48d83), not built here

- A writer echo check like Blurt's `RewriteGrounding`: that thread is
  building a before-caret echo guard in the same place.
- Warming the gateway connection during recording, within the QUIC finding.
- The text before the cursor as the streaming `prompt` (≤1,750 characters),
  only behind the names eval; unverified that STT-3.7 Realtime accepts it.
- Writer `temperature: 0`, if Luna accepts it.
- Not recommended: moving dictation to the Dictation API, and Blurt's
  FrameAligner and 120 s live-cap fallback, which only that API needs.
