# 2026-11-28: iPhone draft, Shift and overlapping dictations

## Why

Two problems left by PR #171 (`activities/2026-11-28-iphone-draft-hosts.md`):
the first letter typed during a draft that ends mid-sentence came out a
capital, and a draft offered while an earlier draft was still marked was
never typed. The second came from a debug probe that wrote drafts straight
into the shared store. In the app it can't happen today: `AppModel.startBlocker`
refuses a new dictation ("Still working on the last one") until the last one
is delivered, from the keyboard, the Action button and Control Center. The
keyboard now handles it anyway, so overlapping dictations can be allowed on
iPhone later (in their own change, measured) without a keyboard change.

## Causes

- Shift: a host tells a keyboard only of changes made elsewhere, and the
  keyboard never refreshed Hex's keys after its own `setMarkedText`, so Shift
  kept the state from before the draft ("Earlier line. " asks for a capital).
- Overlap: a draft was marked only in a poll that began with none held, so a
  second offer went stale. Marking it separately would not work either: a
  keyboard's new marked text replaces the old.

## What changed

- `KeyboardModel.onDraftChange` refreshes the keys after a draft is marked or
  changed.
- `KeyboardDraft` holds one part per dictation; a later transcript joins the
  marked text, each written text takes its part's place in either order, and
  the whole goes in with one `insertText`.
- The app lists drafts whose written text is still to come
  (`SessionSnapshot.writingDrafts`); the keyboard decides whether a draft
  still waits from that list, not from the foreground phase. Written texts
  naming drafts are delivered one at a time, since the snapshot holds one
  result.
- Settings › Advanced › Try drafts in Notes, Mail and WhatsApp (off) for a
  device trial of hosts the Simulator can't run.

## Review

Fable 5.2 scored the first version 80/100 (phase-based waiting, delivery
overwrite, a line break in re-marked text); those were fixed. Codex found
that an earlier part's written text could be typed beside its transcript
after a joined draft ended early; fixed with `typedDraftIDs`.

## Verification

KeyboardDraftTests on the fake host, Core tests for the snapshot and the
trial hosts; iOS 27 Simulator measurements on the Mac mini (results and demo
videos posted on PR #173).
