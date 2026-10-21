# GPT-6 Astra for OpenAI, and writing rules sync through iCloud

2026-10-21.

## Why

- The owner wants one text model per provider for every text role:
  cleanup, Ask Anything, Translate, meeting notes. On OpenAI, `gpt-6-luna`
  could not fix misheard phrases that read as English
  (see `2026-10-21-mishearings-that-read-as-english.md`). The owner chose
  `gpt-6-astra`.
- The writing rules were the only per-user writing setting that did not
  follow the user between the Mac and the iPhone. The dictionary and History
  already sync with no setting.

## What changed

- `OpenAIConfig.writingModel` is `gpt-6-astra`. It already drove every
  OpenAI text role (`openAIChat`, agent mode through `AgentEndpoint`), so
  the change reaches all of them. A user's Formatting model override still
  wins. `PriceBook` has Astra at $10 in, $1 cached, $50 out per million
  tokens (developers.openai.com/api/docs/pricing, 2026-10-21).
- `WritingRulesSync` keeps the rules as `writingRules.v1` in the iCloud
  key-value store the dictionary uses. Newest edit wins. A reset is an edit.
  Rules edited before sync have no stamp; when two such copies meet, custom
  rules win over the defaults.
- `SettingsStore.setCustomInstructions` stamps only real changes, because the
  iPhone editor saves on every close. It stores text equal to the defaults
  as "use the defaults", so a copy of old defaults does not stop later
  default updates.

## Review fixes (PR #16)

CodeRabbit raised five points. Three were fixed:

- Astra has no `none` reasoning effort; its lowest is `low`
  (developers.openai.com/api/docs/models/gpt-6-astra). The app sent `none`,
  so every direct OpenAI writing request would have been rejected and the
  raw transcript inserted. `openAIReasoningEffort(model:)` now sends `low`
  to Astra and keeps `none` for other models, such as a Luna override. The
  earlier Astra numbers came through CLIProxyAPI, which accepted `none`.
  Re-measured at `low`: 22 of 33 fixed (21 at `none`), controls unchanged,
  p50 3.9 s, p90 9.2 s (7.8 s at `none`), gate 75 of 75. The proxy reported
  almost no reasoning tokens at either level, so latency on OpenAI itself
  is not measured.
- Astra calls tools only through the Responses API
  (developers.openai.com/api/docs/guides/function-calling). Agent mode on
  the OpenAI provider used Chat Completions; it now uses the existing
  `.openAIResponses` transport, which the proxy setup already exercised.
- A device could upload its rules before its first iCloud download and
  replace a newer value stored there. The first fix covered only unedited
  copies; CodeRabbit pointed out that an older edited copy had the same
  problem. Now, while iCloud shows no value, only an edit made just now is
  uploaded. Start, refresh, and iCloud-change passes upload only after they
  have read a stored value and merged with it.

Not changed: stamping edits later than the iCloud value when the clock moves
backward (`DictionarySync` has the same behavior and device clocks are
network-synced), and Astra's long-context price above 272K input tokens (no
VoiceiQ request comes near it; cleanup prompts are about 8,300 tokens).

## Cost

The cleanup prompt is about 8,300 input tokens and 30 output tokens
(measured on the replay set). That is about $0.085 per dictation on Astra
before prompt caching, $0.0008 on Luna, and $0.006 on `gemini-3.8-flash`.
Agent mode and long meeting notes cost more on Astra in the same ratio.

## Verification

- `scripts/test.sh`: 143 tests pass. A throwaway XCTest (deleted
  afterwards) checked: the merge is order independent, a later reset beats
  older custom rules, custom rules win the unstamped tie, unchanged text
  keeps its stamp, and text equal to the defaults is stored as nil. The
  iCloud store does nothing in a test process without the entitlement.
- Signed and notarized build (`scripts/release.sh`, 0.6.4) installed on the
  Mac mini. On launch it uploaded `writingRules.v1` (defaults). An edit in
  Settings › Writing rules was stamped and uploaded ("local edit: custom"),
  and "Reset to defaults" uploaded again ("local edit: defaults").
  `syncdefaultsd` logged a saved `KVSRecord` for the key each time. Not
  checked: receiving the change on a second device, because the MacBook was
  offline. That path is the one `DictionarySync` already uses.
- The GitButler sentence for the owner's writing rules, replayed on 11
  failures and 14 controls: Astra fixed 28 of 33 runs (21 without it), Gemini
  3.8 Flash 27 of 33 (24), and all controls passed, including "but" as a
  conjunction.
