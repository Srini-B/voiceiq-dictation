# Shorter dictation prompt (lever 3) and the screen-text cap (lever 4) (2026-11-26)

## Why

Text input is about 95% of a dictation's cost: with prompt caching priced at 0% hits until the app's usage log measures it, every call pays for the whole prompt. At January 2027 prices the owner profile came to ₹344 a month on main, against cyron's gate of ₹250. Meetings account for ₹163 of that. The writing model stays gemini-3.8-flash at thinking level low.

## What changed

- The layout rule ("Before writing, count the separate requests…") was in the rules and again, nearly word for word, as the layout reminder just before the dictation. The copy in the rules is gone; the reminder stays.
- Five examples that repeated an example already inside a rule are gone: the hedge pair ("I think it is available…", "let's ship Friday or maybe Monday"), the restatement pair ("so the plan is we ship the build…", "the api the endpoint I mean"), and the side-note example ("the guy from finance… Rohan").
- The usage log line shows the cached input tokens.

The prompt is 1,925 characters (436 tokens, 5.5%) shorter.

## Measurements

Eval clips from the integrator's scorecard. Each prompt variant was replayed through `eval/dictation/run.py` with the prompt swapped (`.amp/in/orb-backup/sub_run.py`). The ml_*, clean_* and ctrl_* cases ran 4 rounds; the name_* and screen_* cases ran 2 rounds. The baseline is main at 62835c6.

| Variant | Prompt tokens | Calls that thought | Automatic checks | Names | ₹ per dictation, no backups | Owner ₹/month | C1 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| main | 7,981 | 0/76 | 28/32 | 78/78, 0 flips | 1.131 | 344 | 52.5 |
| Recognizer bullets moved to the on-device path (rejected) | 7,425 | 26/76 | 25/32 | not run | 1.185 | 352 | 49.1 |
| This change | 7,545 | 0/76 | 28/32 | 78/78, 0 flips | 1.070 | 334 | 56.4 |

The 4 failed checks in both main and this change are clean_punct, whose check is stricter than its spec. D3 and D4 are left to the Fable judge (packets in `.amp/in/orb-backup/lv3-*.packet.jsonl`).

Moving the two recognizer bullets ("Words that sound alike…", "The recognizer writes what the audio sounded like…") out of the audio prompt made gemini-3.8-flash think on about a third of calls, at about 550 thought tokens each, which are billed as output. p50 rose from 2.6 s to 4.8 s, and ml_hi gained ":00" twice. A rerun reproduced it: 14 of 38 calls thought. A control edit (one blank line after "Rules:") caused no thinking in 38 calls, so the cause is the bullets' content, not a changed prompt or a colder cache. Every later cut is checked for thinking as well as quality.

## Lever 4: not changed

Capping screen text at 2,000 characters instead of 6,000 would save up to about 920 tokens (₹0.13 per dictation at 2027 prices), but only on dictations with dense screens. The eval cannot show either the saving or the risk, because its single screen is 367 characters. The risk: each of up to 4 captures gets an equal share of the cap, which would be 500 characters, and the lines are kept from the top. In a chat app the recent messages, and the names in them, are at the bottom of the screen, so they are dropped first. Deciding needs the size of real screen text, which usage.sqlite already holds as prompt tokens per call.

## Verification

`swift test --package-path VoiceIQCore` (249 tests) on an Amp Mac satellite (macos-27). `eval/promptdump`, built there from this commit, prints prompts byte-identical to the evaluated variant. The lobsters-mac-mini runner was not used because this work could not start other threads.

## Rollback

Revert the commit. Nothing is stored or migrated.
