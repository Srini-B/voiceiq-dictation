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
3. **Comma-set "new line" mid-thought.** Set off by commas, "new line" no
   longer breaks the line when all that follows to the sentence's end is a
   hedge ("I think", "I guess", "probably", …): "She bought a car, new
   line, I think." stays, and "Yeah, I'll ping Sam, new line, thanks." still
   breaks (`SpokenMarks.hedgeEndsSentence`). A first version allowed the
   break only after one or two words; CI's `OnDeviceDictationTests` showed
   that drops a meant break after a longer clause.
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
- D4 on the writing-Off path (Claude Fable 5.2): 96.6 over 332 cases at
  `6b7dffc`, 0 meant words lost; the nine new cases score 100, and every
  case below 90 is a shortfall the fixture already records (`tidy`).
- Codex: an already-written address before "and" stopped a spoken one
  from joining ("Mail priya@gmail.com and ravi at the rate gmail dot
  com."); fixed in `8ae76c8`, with a case in `TidyTests`.
- Neon probes (52 inputs, Mac mini, 8ae76c8 against main): every fix
  shows; one Medium, "The market is moving at the rate google dot com,
  thanks." → "moving@google.com". The new endings (", thanks", "and"
  another address) now need a strong introduction (the clause's start,
  "email", "mail", "cc", …, or "is"/"to" after one); "is", "to" or a
  written address alone join only where the address ends the sentence, as
  on main. A Low: "No." read as the "No. 5" abbreviation made "Is it ok?
  No. Call me later. See you." count as three sentences; "No." is an
  abbreviation only before a number now. Neon also listed false joins
  main already made at a sentence's end, the same class as item 1 ("It is
  growing at the rate amazon dot com." → "growing@amazon.com"): after a
  weak introduction, an "-ing" word of six letters or more, or a number, is
  no mailbox now. "Use growth at the rate google dot com." still joins.
- Codex and Neon rounds after that found joins main made and #131 had
  lost: an address after a heading line, after "email's" or "It's", after
  "to billing" or "to 123", and an address list after "to". Each is fixed
  with a case in `TidyTests`. A scratch harness then compared
  `SpokenAddresses.joining` against main's over 2,100 generated
  dictations (30 introductions × 7 mailboxes × 10 endings): the only joins
  main makes and this branch does not are "Prices rose X…" (item 1) and
  "It is" / "It's" before a long "-ing" word or a number, both meant.
- Neon (agy, gemini-4-neon-high) at `c3c1584`: no High; two Mediums fixed.
  "Prices rose and fell at the rate gmail dot com." joined "fell@…": after
  "and"/"or" with no address just before, a mailbox now needs an
  introduction earlier in the sentence (or "and" opening it), and is never
  a number. "It will be growing at the rate amazon dot com." joined: "be"
  now counts as progressive, while a strong word earlier in the sentence
  ("My email will be billing at the rate…") still joins. Left as Lows that
  keep the words: a written address second in a list, a comma before
  "and", a dotted mailbox starting with an -ing word, "No, 15,000, I mean,
  50,000 dollars" not resolved, and "Wait, what question mark?" (as on
  main).
- CI runs `swift test --package-path VoiceIQCore` on Xcode 27.

## Follow-ups after the merge (Neon agy review of #131, session bad480e5)

No High. Fixed on branch `tidy-followups`:

- "at the rate" false joins at a sentence's end:
  - After "and" or "or", only a strong word or a written address earlier in the sentence introduces a list; a weak one ("in", "to") no longer does ("Prices in Europe rose and fell at the rate gmail dot com." stays).
  - The -ing and number guard now runs before a strong word within three words promotes the join ("Tell me it will be growing at the rate amazon dot com." stays). A word naming the address ("email", "address", "id") still joins "My email will be billing@gmail.com."
  - A comma before a long "-ing" word or a number no longer counts as an introduction ("Prices kept rising, growing at the rate gmail dot com." stays).
- Messages style: a title word's full stop ("Jr.", "Inc.") is dropped only when it is the message's one full stop; "Thanks. Ask Martin Luther King Jr." keeps it.
- Left as intended: "Order 12, I mean, $15." and the one-word "Nice exclamation mark." → "Nice!".

Each case is in `TidyTests`, and each fails on main's sources and passes here (Linux harness, Swift 6.2.1, 15 tests including the 334 cleanup cases).

D4 writing-Off at the follow-up PR's head (Claude Fable 5.2,
T-01a2218d-e69c-724f-a8b2-916f4a675e7f), number of record for Tidy after #131:
**97.05 over 334 cases at `752876e`, 0 meant words lost**. All 334 outputs are
byte-identical at `ab6b516`, so the score holds there. There are 310 exact matches
and 23 cases below 90, all of them under-cleaning that the fixture already records as `tidy`:
unresolved self-corrections, a kept "I mean", leftover spoken marks and
quoted addresses, and "When is Sam free." without a question mark. #131's 96.6
was scored at `6b7dffc`, 10 commits before its head, over 332 cases.
