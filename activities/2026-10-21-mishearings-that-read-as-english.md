# Writing rules: fix mishearings that still read as English

2026-10-21.

## Why

Two MacBook dictations into Amp (local `fluid-speech-mini`, cleaned by
`gpt-6-luna` at reasoning `none`) came out grammatical but wrong:

- RAW "merge up here" (said: "merge the PR") became "merge it here".
- RAW "downloaded and then stored automatically" (said: "installed")
  became "downloaded and stored automatically".

The last 120 MacBook dictations had more of the same kind: "butt conflict"
became "merge conflict" (said: `but config`), "on my voice … iPad voice"
(iOS, iPadOS), "file icons" (favicons), "commons" (comments), "dictation
nerve" (now), "INL price" (INR).

The rules told the model to change a word only when it "does not fit its
phrase" and to keep "a word that already reads correctly". A
recognizer's mistakes read correctly, so the rule protected them.

## What changed

- `PromptV1.rules`: the rule about similar-sounding words now says a
  grammatical phrase is not evidence. The model works out what the speaker
  is doing, checks each phrase against it, and replaces a phrase that does
  not belong with the similar-sounding phrase that does. It must not
  trade it for another phrase that is only grammatical. It keeps RAW when
  nothing fits.
- `DictationRulesSeed`: the same rule in the user-editable default, and a
  "read it as the receiver" question in the final check.

## Verification

Harness `.amp/in/sensefix/` (not committed). It builds the app's exact
cleanup prompt (default writing rules, the MacBook dictionary, the app as
PLACE) and calls the CLIProxyAPI endpoint. It has 10 real failures from
MacBook history and 13 controls: correct unusual phrases, names, a real
"lock files", "merge it here" used correctly, and the CONTRIBUTING set
(self-correction, list, question, spoken punctuation, injection).

| Model (reasoning `none`) | Old rules: fixed | New rules: fixed | Controls (new) | p50 / p90 latency |
|---|---|---|---|---|
| gpt-6-luna | 8/40 | 7/40 | 48/52 | 2.6 s / 3.5 s |
| gpt-6-luna, `low` | 8/40 | 9/40 | 48/52 | similar |
| gpt-6-luna, `medium` | n/a | 5/20 | 24/26 | 0 reasoning tokens on most fixtures |
| gpt-6-sol | 8/20 | 10/20 | 24/26 | |
| gpt-6.1-sol | n/a | 19/30 (with reminder) | 36/39 | 3.2 s / 6.5 s |
| gpt-6-astra | 17/30 | 23/30 | 36/39 | 3.6 s / 6.2 s |
| claude-sonnet-5-5 | 18/30 | 18/30 (with reminder) | 36/39 | 2.8 s / 6.1 s |
| claude-haiku-5-5 | n/a | 1/30 (with reminder) | 33/39 | |
| claude-opus-5-5 | 19/30 | 20/30 | 36/39 | 2.7 s / 4.7 s |
| gemini-3.8-flash, thinking `low` (the app's call, direct API) | 24/30 | 24/30 | 36/39 | 2.3 s / 3.1 s |
| gemini-4-argon, thinking `low` (direct API) | 21/30 | 24/30 | 36/39 | 3.8 s / 10.9 s |

The only control that fails is "run but status" (GitButler), and it fails
for every model and both prompts: the models write `git status`.
ValidationGate accepted all 299 outputs it was given.

Also measured and rejected:

- A reminder before RAW, like the layout reminder: Astra 24/30 with it,
  23/30 without. That is noise, so it was removed.
- A `HEARD:` list before `CLEAN:`: no gain on Luna. On Sol the output
  format broke in most runs.
- A separate hearing-check call (Sol) before Luna's cleanup: 24/30, the
  same as one Astra call, plus a second round trip of about 2.6 s.

Luna is the limit. Asked only "which phrases are misheard?", Luna found
about 4 of 10 and Sol found 9 of 10. The new rules help a model that can
do this (Astra +6) and cost nothing on Luna.

A second gate run on the Gemini, Opus, and Astra outputs accepted 270 of
276. It turned down "Merge the stacked PR." for RAW "Mudge the stack peer"
(only 1 of 4 words kept). It also turned down two Opus outputs that grew
3.2 to 3.6 times longer than RAW.

Model choice: one model per provider does every text role (cleanup, Ask
Anything, Translate, meeting notes). `gemini-3.8-flash`, the existing
Gemini default, fixed the most and was the fastest. Opus 5.5 was not
better than Gemini or Astra, so no Anthropic provider was added. For
OpenAI, `gpt-6-astra` is the model that does this; `gpt-6-luna` is not.

`scripts/test.sh`: 143 tests pass.
