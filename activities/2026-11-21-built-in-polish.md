# Polish built into the writing rules

2026-11-21.

## Why

The user compared VoiceiQ's writing pass with Wispr Flow's Polish
transformation (reword for clarity, reorder for readability, add structure
for readability, maintain your tone; "make more concise" off) and wanted the
same result. He asked for it built in: no toggles, no option, no shortcut.

The built-in prompt deliberately did the opposite of Polish. `PromptV1.rules`
said "keep the order of ideas" and "never reword a clear sentence, and never
make the speaker sound more polished than they were"; `DefaultWritingRules`
said "prefer local edits over global rewrites … do not reorder paragraphs
merely to look polished". The model kept spoken phrasing such as "make the
same changes to us for these three sections".

## What changed

- `PromptV1.rules`: three "Polish:" rules (reword, reorder, structure), the
  opening describes the polished draft, and the two clauses above are gone.
- `DefaultWritingRules`: the local-edits rule is now "edit like the speaker
  polishing their own draft, not like a ghostwriter"; the voice rule no longer
  forbids "concise" but forbids shortening beyond dropped padding; the final
  check asks whether the speaker would recognize every sentence as theirs.
- `PromptV1.examples`: a design-doc handoff (context, one item per action,
  closing reason below) and a request whose reason was spoken later.
- `PromptV1.layoutReminder`: a bundled request may become one item per
  action; a closing note covering the whole list stays below it.

The rule's own examples use different wording from the user's sample, so the
sample stays a fair test.

## Verification

Harness `.amp/in/orb-backup/polish/` (not committed): it builds the app's
exact cleanup prompt from the Swift sources of a revision and calls
`gpt-6.1-terra` with `reasoning_effort: none` in one user message, as
`GeminiClient.openAIChat` does, and ports `ValidationGate.validate`.
15 dictations, 2 runs each per prompt: the user's sample, 6 polish cases,
and the CONTRIBUTING set (self-correction, spoken list, spoken punctuation,
question, all-filler).

| | main | this change |
|---|---|---|
| Median writing call | 1.62 s | 1.50 s |
| Median, 5 long dictations | 2.08 s | 2.12 s |
| Mean output tokens | 53.0 | 50.7 |
| Prompt tokens (cached prefix) | 8,046 | 8,808 |
| Gate rejections | 0 | 0 |

One uncached call took 6.06 s; the first call after any prompt change pays the
uncached prefix once. Self-correction, spoken list, spoken punctuation,
question, chat, and casual messages came out identical on both prompts. The
all-filler take came back empty on both, which the gate turns into the
filler-stripped transcript, as before.

User's sample, main:

> Go over the Hex GitHub repository URL that I gave you. They've been making
> some good progress on making the keyboard, swipe-to-type, and prediction
> model better than what we have right now.
>
> 1. Discard everything that we have built right now for the prediction
>    model, swipe-to-type, and keyboards, and replace all three with the ones
>    from Hex.
>
> 2. Create a schedule that will check the repository daily for any changes
>    and improvements they make so that we can bring those in to us as well.
>    They are constantly making changes, so we'll also pull in the changes
>    daily and make the same changes to us for these three sections.

This change (one of four runs of the final prompt; the other three kept discard and replace as one item, and one of them put the closing reason in its own paragraph below the list, as Wispr does):

> Go over the Hex GitHub repository URL I gave you. They've been making good
> progress on the keyboard, swipe-to-type, and prediction model, and they're
> better than what we have right now.
>
> 1. Discard everything we've built for the prediction model, swipe-to-type,
>    and keyboards.
>
> 2. Replace all three with the versions from Hex.
>
> 3. Create a schedule to check the repository daily for changes and
>    improvements. They're constantly making changes, so we'll pull them in
>    daily and make the same changes to our three sections.

Wispr Flow split the actions more reliably and went more formal ("Review", "significant progress", "surpassing our current
implementation", "promptly"). The new rules keep the speaker's words and
contractions instead, on purpose ("maintain your tone").

Not verified: Gemini (`gemini-3.8-flash`) as the writing model, and a spoken
dictation through the installed app.
