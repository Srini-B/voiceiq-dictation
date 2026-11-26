# 2026-11-26: Meeting notes, actions and owners

## Why

A Fable 5.2 judge scored the notes from PR #82 at a mean of 85.3 (M5), with 4 of
9 meetings at 90 or more. It found no invented commitments and no wrong owners.
Points were lost because:

- Actions sat in prose. In s3 the action list held 1 of 4 tasks.
- Owners were missing. In s4, Kenji was named by elimination only after the
  notes were written.
- AMI's problem and next step were dropped.
- A 69-second call got six sections.
- A Risks bullet stated what nobody said.

## What changed

- The notes rules: every owned task in `actions`, one per task; a later
  decision is an action; an agreed group next step is an unowned action; the
  "I'll" speaker owns the task, by name; deadlines stay with their task; every
  voiced problem is kept and unvoiced risks are not; short calls get short
  notes. The status-update type's "Coming up" section now covers events and
  dates, and leaves tasks to `actions`.
- `MeetingEngine.writeNotes` writes the notes again when `byElimination` names
  a voice the first notes left unnamed. That costs one more notes request,
  only on such calls.
- **Round 2 regression (M5 83.1).** Both s2 runs came back with
  `actions: []`, although the call had four spoken commitments. The new owner
  rule ("the "I'll" speaker owns it, by name") likely left the model with
  owners it had not named yet. Two fixes:
  - A check after generation: `MeetingNotesPrompt.missingActions` lists
    every transcript line with "I'll", "I will", "I can" or "I'm going to".
    When the notes have no action items and that list is not empty,
    `GeminiClient.meetingNotes` asks once more with those lines quoted, and
    keeps the second reply only if it has actions.
  - A speaker the model names in `speakers` owns their tasks under that name.
- Notes never show a raw "Speaker 3" label, and keep the speaker's hedge
  ("probably") wherever a point appears.
- Eval: `EVAL_TRANSCRIPTS=DIR` reuses an earlier run's transcripts and writes
  only the notes. The transcription quota ran out on 2026-11-26
  (`retryAfter` about 22 h).

## Decisions

- **Elimination re-writes the notes, instead of a prompt rule.** A prompt rule
  telling the model to eliminate did not fire on s4. The deterministic rule
  already in `ScreenSpeakerNames` names the voice, and the second request sees
  the name the way it sees a name read from the screen.
- **s1's trial-length fix stays merged with the Figma task.** The script says
  "fix that in the same pass", so the Thursday date is the speaker's.

## Verification

- s3: 4 of 4 actions, with owners and Wednesday dates.
- s4 and s4-echo: Kenji Watanabe owns the usage-numbers action.
- AMI: the group next step is an action.
- `swift test --package-path VoiceIQCore`: 246 tests, 0 failures.
- Round 2 judged 83.1: s3 and s4 at 92 to 95, s2 at 50 and 60.
- Round 3 (c4ed268) judged 92.6, with 8 of 9 meetings at 90 or more and
  nothing invented: ami 88, s1 92, s1-echo 93, s2 95, s2-echo 94, s3 94,
  s3-echo 94, s4 91, s4-echo 92. s2 had 4 or 5 actions in all 6 runs.
- After round 3: a cost or doubt raised about an idea stays next to it; a
  doubt is not filed as an idea; a task's deadline appears once; a group
  next step says what it prepares for; claims keep their scope. On the saved
  transcripts, AMI's action now reads "Work on individual tasks for
  functional design before reconvening (in half an hour)". Not judged yet.
- "host contract" in s4 is Gemini's transcript ("hosting contract" was
  said); the notes copy it faithfully.
- Not fixed: AMI's recorded problem (the budget may not cover every feature)
  is voiced only as "I think that's a cost thing", so the notes leave it out.

## Rollback

Revert the commit. Nothing is stored differently.

## Review fixes (Gemini 4 Neon on main ddcefe1..884208e)

- **Finding 3 (release blocker).** After the elimination rewrite,
  `MeetingEngine.writeNotes` returned only the second notes. It dropped the
  elimination result, and `finish` eliminated again from those notes. If they
  left out a self-introduced speaker, the transcript kept "Speaker N" while the
  notes gave actions to the eliminated name. `writeNotes` now stores the name
  in `meta.screenNames`, and `finish` finds nothing left to eliminate. Names
  the first notes found and the rewrite left out are carried over.
- **Finding 11.** A far-side voice is folded only below 1% of the meeting and
  below 15 s, so 30 s in an hour-long call stays a participant.
- **Finding 13, partly.** `prepare.py` skips AMI words without times instead
  of crashing.
- Not changed: finding 9a (the silent download is a recorded decision, above
  and in the hybrid entry); `missingActions` stays English-only, and when it
  misses a commitment the notes are kept as written; the eval's app id and
  duration source.
