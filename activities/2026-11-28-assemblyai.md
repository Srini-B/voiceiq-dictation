# 2026-11-28: AssemblyAI replaces Gemini for dictation, meetings and notes

## Why

cyron decided to move VoiceiQ fully to AssemblyAI and remove Gemini, with a
budget under ₹400 a month (₹200–250 preferred) for about 160 dictations and
4 meeting hours a month. The research and cost plan is the artifact
"VoiceiQ on AssemblyAI only: costs and plan" in thread T-51b48d83. The
Dictation API ($0.62/hr) was rejected: it runs Universal-3.6 Pro, lets a
custom writer use only three small models, and costs more than STT-3.7
Realtime plus a gateway writer at every dictation length.

## What changed

- **Dictation** streams to STT-3.7 Realtime (`RealtimeTranscription`) while
  the user speaks; at key-up `ForceEndpoint` returns the last turn. GPT-6
  Luna on the LLM Gateway writes the transcript by `PromptV1` (now a text
  prompt). A failed stream, or an empty one, falls back to pre-recorded
  STT-3.7 on the recording; languages outside STT-3.7's 32 use Universal-2.
  Send-on-pause, the hedge and chunked Gemini dictation are gone.
- **No keyterms.** The Dictionary goes to the writer only (see the eval).
- **Writer fallback.** When the gateway fails, including the 400 an account
  without a balance gets, the transcript is inserted tidied on device with a
  pill notice (`TranscriptionError.noBalance`).
- **Meetings**: each track's speech stretches go to pre-recorded STT-3.7
  (speaker labels on the far side and mixed requests), up to an hour of
  speech per request; the on-device speaker model still splits the far
  side. Notes (JSON schema) and meeting chat go to Luna on the gateway.
- **Settings**: an AssemblyAI key replaces the Gemini key, which the first
  launch deletes with the Gemini endpoint and model overrides. A Language
  setting (English default) picks STT-3.7 or Universal-2.

## Eval (dictation, 38 TTS clips; spend from the free credit and OpenRouter)

| Run | D1 names | D2 | D4 | D5 p50 / p90 | Notes |
| --- | --- | --- | --- | --- | --- |
| Gemini baseline (0.7.16) | 100 | 99.2 | 94.25 | 3.0–3.4 s | |
| 3.7 RT + keyterms + Luna (`luna-r3`) | 77.9 | 96.5 | 89.8 | 1.31 / 1.67 s | Karen→Karan, Rowan→Rohan from keyterms |
| 3.7 RT, no keyterms + Luna (`luna-nokt`) | **95.7** | 96.9 | not judged | 1.29 / 1.86 s | 0 control flips; misses Vercel, Joaquín |
| + gemini-3.5-flash-lite (`flashlite-r2`) | 66.8 | 97.7 | | 1.43 / 1.64 s | 4.6× Luna's cost per call |
| + gemini-3.8-flash (`flash38-r2`) | 40.0 | 95.2 | | 2.57 / 3.75 s | 13× Luna's cost per call |

Luna stays the writer: cheapest and best on names. D3 (other languages):
de/es/fr/hi average 96.5; Tamil scores 5–40 because STT turns it into
English, accepted. Writer quality is measured through OpenRouter because the
free credit does not cover the LLM Gateway.

Spend: AssemblyAI free credit about $0.08 (STT runs); OpenRouter about
$0.48 (writer runs); OpenAI TTS about $0.03.

## Cost (₹93/$, owner profile)

About ₹149 a month at a 20 s average dictation, ₹174 at 40 s, ₹200 at 60 s:
dictation ₹38–89, meetings about ₹111 (₹28 per hour of speech). Only the
gateway part, about ₹15 a month, needs a paid balance; the rest comes out
of the $50 credit.

## Not done

- The meetings eval (M1–M5) on AssemblyAI: needs the Mac and, for notes, a
  gateway balance; transcripts alone score M2–M4.
- Speaker Identification is supported by the client but not sent.
