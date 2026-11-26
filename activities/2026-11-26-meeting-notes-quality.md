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
- `swift test --package-path VoiceIQCore`: 245 tests, 0 failures.
- M5 judging of the new packet is with the integrator.

## Rollback

Revert the commit. Nothing is stored differently.
