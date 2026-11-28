# 2026-11-28: Tidy's known shortfalls (#103)

## Why

Issue #103 listed nine places where the writing-Off tidy-up (`Tidy`) wrote
something worse than it could, with no word lost. Since the AssemblyAI
switch (#121), Tidy is also the fallback when the writing gateway is down,
so it runs more often than when the issue was filed. #123 (the cleanup
guard port) changed none of the nine: each one still reproduced at
`efc739f`.

## What changed

1. **"at the rate" after a verb.** With "at the rate", the mailbox must
   open the sentence or a clause, or follow a word that introduces an
   address ("is", "to", "mail", "email", "cc", …). "Prices rose at the rate
   gmail dot com." stays as said (`SpokenAddresses.introducesAddress`).
2. **Repeated hesitations.** Not changed. See Decisions.
3. **Comma-set "new line" mid-thought.** After a written comma, "new line"
   breaks the line only when one or two words come before it ("Thanks, new
   line, Sam", "Hi team, new line, please review"). "She bought a car, new
   line, I think." stays (`SpokenMarks.saysLayout`).
4. **Number swap before a unit.** A correction that adds a unit no longer
   replaces a number that names something ("flight", "room", "gate",
   "page", …): "Flight 101, I mean, 102 minutes." stays, and "It took 101,
   I mean, 102 minutes." still becomes "It took 102 minutes."
   (`SpokenRepairs.labels`).
5. **Two "at the rate" addresses.** An address may end before "and" or "or"
   when another address follows: "Mail priya@gmail.com and ravi@gmail.com."
6. **Address before a comma.** An address may end before a comma when only
   "please", "thanks", "thank you" or "cheers" follows to the sentence's
   end: "priya@gmail.com, please." Other words after the comma keep it as
   said ("…, Walmart and Target agreed.").
7. **One-word clause before a spoken mark.** An end mark's name converts
   after one word when the word is said as an exclamation or a question of
   its own ("great", "thanks", "really", "wow", …): "Great! See you soon."
   A describing word ("Double exclamation mark") stays.
8. **List item comma.** A list line no longer ends with a comma or a
   semicolon: "Groceries:\n- Milk\n- Eggs".
9. **Messages after a title.** The input was never recorded; "Ask Prof.
   Iyer and Sgt. Lee and Capt. Rao." reproduces it, because each title's
   full stop counted as a sentence end and the message passed the
   three-sentence limit. Titles and abbreviations no longer count, so the
   final full stop goes as in any short message.

Each item has a case in `TidyTests` beside its near miss, and a case in
`cleanup-cases.json` so D4 scores it. Each new assertion fails at `efc739f`
and passes here, except item 2's, which pins the current behaviour.

## Decisions

- **Item 2 stays.** "uh" is a hesitation in Sentences, Messages and Lists
  by contract ("Full sentences, with um and uh dropped"), and three of them
  are three hesitations. Telling a meant stammer from a pause needs the
  audio or the context, which rules do not have. The speaker who wants the
  stammer written picks As spoken, which keeps it; a test covers both.
- **Lists of words, not grammar.** Each fix narrows a rule with a short
  closed list (address introductions, labels, exclamations, courtesies), so
  anything outside a list falls back to the words as said.

## Verification

- Linux harness (Swift 6.2.1, the six Tidy sources and `TidyTests` /
  `CleanupCasesTests`): all pass, 332 cleanup cases.
- Pending: `swift test --package-path VoiceIQCore` on the Mac mini, CI,
  Neon review and D4.
