# Polish built into the writing rules

2026-11-21.

## Why

The user compared VoiceiQ's writing pass with Wispr Flow's Polish
transformation (reword for clarity, reorder for readability, add structure
for readability, maintain your tone; "make more concise" off) and wanted the
same result, built in: no toggles, no option, no shortcut. On tone he said
what he speaks will not be grammatically correct, so it must be corrected,
formatted, and made sense of, and unnecessary words must be stripped out. No
formal rewording.

The built-in prompt did the opposite. `PromptV1.rules` said "keep the order
of ideas", "never reword a clear sentence", and "repair obvious grammar …
conservatively"; `DefaultWritingRules` said "prefer local edits over global
rewrites … do not reorder paragraphs merely to look polished" and "remove
only genuine speech artifacts". The model kept phrasing such as "the URL that
I gave you" and "make the same changes to us for these three sections".

## What changed

- `PromptV1.rules`: three "Polish:" rules (reword, reorder, structure), a
  rule to strip unnecessary words while every meaningful word and qualifier
  stays as spoken, and a rule to fix the grammar fully. The opening describes
  the polished draft. The clauses above are gone.
- `DefaultWritingRules`: "edit like the speaker polishing their own draft,
  not like a ghostwriter"; fix every grammar mistake; remove words that
  carry no meaning; the voice rule no longer forbids "concise" but forbids
  shortening beyond dropped padding.
- `PromptV1.examples`: a design-doc handoff (context, one item per action,
  closing reason below) and a request whose reason was spoken later.
- `PromptV1.layoutReminder`: a bundled request may become one item per
  action; a closing note covering the whole list stays below it.

The rules' own examples use different wording from the user's messages, so
those messages stay a fair test.

## Verification

Harness `.amp/in/orb-backup/polish/` (not committed): it builds the app's
exact cleanup prompt from the Swift sources of a revision and calls
`gpt-6.1-terra` with `reasoning_effort: none` in one user message, as
`GeminiClient.openAIChat` does, and ports `ValidationGate.validate`. On the
Mac mini, `PromptV1.cleanupPrompt(raw: "X")` from Swift matched the harness's
prompt byte for byte (first round). 18 dictations, 2 runs each per prompt:
three of the user's own dictated messages, a messy repeated-words take, 6
polish cases, and the CONTRIBUTING set (self-correction, spoken list, spoken
punctuation, question, all-filler).

| | main | this change |
|---|---|---|
| Median writing call | 1.72 s | 1.69 s |
| Median, 7 long dictations | 2.03 s | 1.92 s |
| Mean output tokens | 53.0 | 51.0 |
| Prompt tokens (cached prefix) | 8,046 | 9,126 |
| Gate rejections | 0 | 0 |

Self-correction, spoken list, spoken punctuation, chat, casual, and email
came out identical on both prompts. The all-filler take came back empty on
both, which the gate turns into the filler-stripped transcript, as before.

An earlier draft turned "will definitely not be grammatically correct" into
"probably not" and "not necessarily", and dropped "kind of" from "kind of
annoying". The rule now says a qualifier stays exactly as strong as spoken;
3 of 3 runs then kept both.

### Examples (main, then this change)

Hex request. Main:

> Go over the Hex GitHub repository URL that I gave you. They've been making
> some good progress on making the keyboard, swipe-to-type, and prediction
> model better than what we have right now.
>
> 1. Discard everything that we have built right now for the prediction
>    model, swipe-to-type, and keyboards, and replace all three with those
>    from Hex.
>
> 2. Create a schedule that will check the repository daily for any changes
>    and improvements they make so that we can bring those in as well. They
>    are constantly making changes, so we'll also pull in the changes daily
>    and make the same changes for these three sections.

This change (both runs had this layout):

> Go over the Hex GitHub repository URL I gave you. They've been making good
> progress on the keyboard, swipe-to-type, and prediction model, making them
> better than what we have.
>
> 1. Discard everything we've built for the prediction model, swipe-to-type,
>    and keyboards.
>
> 2. Replace all three with Hex's versions.
>
> 3. Create a schedule to check the repository daily for changes and
>    improvements so we can bring those in as well.
>
> They're constantly making changes, so we'll pull them in daily and make the
> same changes to our three sections.

Tone message. Main:

> The goal is that whatever I speak will definitely not be grammatically
> correct, so it needs to be corrected, formatted, and made sense of. Once
> this has been achieved, then we are good.
>
> Even in these messages, whatever I spoke will have unnecessary words in it.
> Those need to be stripped out.

This change:

> Whatever I speak will definitely not be grammatically correct, so it needs
> to be corrected, formatted, and made sense of. Once that's been achieved,
> we're good.
>
> Even in this message, what I spoke will have unnecessary words that need to
> be stripped out.

Build request. Main:

> Build all the improvements, but I don't want the iPhone warm window,
> optional keep mic open, and disabling the Bluetooth microphone. On the four
> keyboard gaps, leave out what can't be done and do the rest.

This change:

> Build all the improvements except the iPhone warm window, the option to
> keep the mic open, and disabling the Bluetooth microphone. Of the four
> keyboard gaps, leave out any that can't be done and do the rest.

Messy take ("so um what I'm saying is that the the pill it should it should
not be showing when the when you are not recording because right now …").
Main:

> The pill should not be showing when you are not recording, because right
> now it is showing all the time, and that's kind of annoying for the users.
> It is also taking up space on the screen, which we don't want right now.

This change:

> The pill shouldn't show when you're not recording. Right now, it's showing
> all the time, which is kind of annoying for users, and it's taking up space
> on the screen, which we don't want.

Wispr Flow's Polish of the Hex request went more formal ("Review",
"significant progress", "surpassing our current implementation",
"promptly"). The user asked for correct, clear, stripped text, not formal
wording, so the rules keep the speaker's words and contractions.

Not verified: Gemini (`gemini-3.8-flash`) as the writing model, and a spoken
dictation through the installed app.
