# 2026-11-28: The writer no longer repeats text already before the cursor

## Why

The #130 latency run on main 4b3276f9 (TextEdit, 14 dictations) found the
written text starting with what the field already ended with: "[1] [1]
Okay…" and "[7] 2] Let's meet…". The swap was right; the writer had copied
the line's prefix into its answer, and a single paste carries the same
error. The release thread made it a 0.7.19 gate.

## Reproduced

`eval/dictation/echo.py`: 30 dictations into fields that end with a prefix
the speaker did not say (`echo_cases.json`: `[7] `, `3. `, `- `, `10:42 `,
labels, greetings, the end of the last sentence, mid-sentence), each with the
document as screen context, through the app's own prompt (eval/promptdump)
to gpt-6-luna at effort none on the LLM Gateway, 3 rounds. Two cases are
spoken repeats that must stay.

| Prompt | Echo from the writer | Echo inserted, with the guard |
|---|---|---|
| main | 5 of 90 (`3. ` ×3, `[2] `, `- `) | 0 of 90 |
| first FIELD rule | 7 of 90 | 0 of 90 |
| shipped FIELD rule | 1 of 90 | 0 of 90 |

The guard changed no other output across the 270 answers. After review,
three spoken-repeat cases were added (a greeting said after "so um", a year
after a year, a one-word last line). On the final prompt and guard, 33 cases
× 3: the writer echoed 2 of 99 and 0 of 99 reached the field. The guard kept
all three spoken starts; the writer itself left out the re-said greeting and
"Okay" when the field already ended with them, which avoids "Hi Priya, Hi
Priya," and is accepted.

## What changed

- `PromptV1.fieldSection`: the text before the cursor is already in the
  field; when it ends with a list or line marker or a label, CLEAN is that
  item's text without it, and CLEAN never starts with the field's last
  words unless RAW does. The first wording (a list of what not to repeat)
  did not lower the rate; this one names the marker as already typed.
- `ValidationGate.droppingEcho`, run on every written answer in
  `AssemblyAITranscriptionService` (and in eval/promptdump): a start that
  repeats the end of the text before the cursor is dropped when the
  transcript does not start with the same words. It drops only a line
  marker or label (punctuation or a symbol, not a plain number), a name with
  its comma, or several words; a lone word stays, and so does a start the
  speaker said within the first few words after fillers, or a number when the
  transcript's first word is that number ("three" written "3."; "okay,
  one more thing" after "[1] " is still an echo). Review findings
  (Neon hand read via agy, Codex) led to those last three conditions.
- `eval/dictation/writer.py` passes the field text and transcript to the
  same post-processing, so the eval matches the app.

## Checks

- D-set, gw-luna-echofix (rt-nokt-all transcripts, 3 rounds): D1 95.7,
  D2 98.0, D5 100; D4 94.2 judged by Fable (gate 90, record 94.2). The one
  field case, clean_field, reads "push the launch to next week" in all
  rounds. That run had the prompt change without the guard wired into
  writer.py; the guard cannot fire on it (its field text is mid-sentence
  and the answer starts with new words).
- Unit tests in `ValidationGateTests`: the echoes are dropped, and a spoken
  repeat, a lone word and "3.5" after "3." stay.
- Not rerun on a signed build in TextEdit; the "2]" case (a changed number,
  not an exact repeat) is left to the prompt.
- Cost: $0.13 of gateway calls.
