# Send-on-pause and streamed dictation requests (2026-11-26)

## Why

Key-up to text was about 2.7 s at the median and 4–9 s at p90, almost all of it Gemini's answer time. Sending the same request twice at the same moment showed the two copies' times correlate at 0.93: the slow tail is the API's state at that moment, so a backup request trims little of it. Only starting the request before key-up moves the median. VoiceiQ is press-to-start, press-to-stop, so the speaker finishes, then reaches for the key. cyron's budget allows about 10% extra billed calls for the backup and early requests together, and Gemini cost must stay under ₹250 a month.

## What changed

- Dictation requests stream (`streamGenerateContent?alt=sse`). Gemini bills nothing for a stream cancelled before its first chunk (Gemini API billing FAQ, "Am I charged for failed, blocked, or canceled requests?"), and a dictation's answer arrives in one to six chunks within half a second of the first, so a request cancelled before it answered costs nothing. The losing attempt of the backup race is cancelled, as before; it is now unbilled.
- Send-on-pause: while recording, once the speaker has said at least 1 s and then been silent for 1 s, the request goes out for the speech so far. Speech after the pause cancels it and the next pause may send again, at most 3 times. At key-up it is used only when `AudioChunker` trims the finished recording to exactly the same speech and the prompt is unchanged; otherwise it is dropped and the normal request goes out. Recording still stops at key-up and everything said is sent.
- The capture engine keeps the first 120 s of written samples and their 10 ms levels in memory, framed as `AudioChunker` frames the file, so the pause check and the key-up trim use one voicing rule.

## Measurements

Streaming against a plain call, 66 pairs sent back to back: time to the last chunk p50 2.72 s against 2.88 s, p90 5.82 s against 5.77 s.

Silent gaps inside speech by `AudioChunker`'s voicing rule:

| Corpus | Clips | Gaps of 0.8 s+ per minute | 1.0 s+ | 1.2 s+ |
| --- | --- | --- | --- | --- |
| LibriSpeech dev-clean sample (read) | 73 | 1.0 | 0.6 | 0.25 |
| AMI headset, test segments of 8 s+ (spontaneous) | 65 | 7.8 | 5.4 | 3.1 |

Replay of the chosen rule (1 s pause after 1 s of speech, cancel on resume, 3 sends) on the same clips, with the 198 answer times measured from the orb, the key pressed G s after the last word:

| Corpus | Requests sent per 100 dictations | Billed and unused per 100 | Used at key-up per 100 (G ≥ 1 s) | Mean time saved, G = 1.5 s / 2 s |
| --- | --- | --- | --- | --- |
| LibriSpeech | 100 | 0 | 95 | 0.47 s / 0.95 s |
| AMI | 165 | 2 | 95 | 0.48 s / 0.95 s |

A single early request at 0.8 s with no cancelling, the first design, fired mid-speech on 43 of 65 AMI segments and would have been billed on about half of all dictations. When the key comes less than 1 s after the last word nothing is sent early and nothing is saved.

With the backup forced at 1.5 s on all 33 eval cases, 33 backups were sent and 1 was billed: the loser had streamed its first chunk by the time the winner finished. Expected extra billed calls per 100 dictations: backup well under 1 (it is sent on 5–9 of 100 at the 4–6 s delay), early requests 0–2. A dictation that sends three requests (an early one, the key-up one and a backup) is billed for more than one only when two of them answer at the same moment. Requests sent but cancelled still count against the per-minute request quota.

## Not measured

The real gap between the last word and the second key press. Every dictation now logs it (`send-on-pause: key-up N s after the last speech`) with what the early request did (`sent`, `used`, `cancelled, speech resumed`, `dropped`, each with `billed:`), so the hit and waste rates come from the debug log or `log show --predicate 'eventMessage CONTAINS "send-on-pause"'`.

## Verification

`swift test --package-path VoiceIQCore` (257 tests, including the trim equivalence, the coordinator's send/cancel/use sequence, the service using or dropping the early answer, and a recorded streamed answer) and unsigned `xcodebuild build` of VoiceIQ and VoiceIQiOS on an Amp Mac satellite (macos-27). The lobsters-mac-mini runner was not used because this work could not start other threads.

## Rollback

Revert the PR. Nothing is stored or migrated.
