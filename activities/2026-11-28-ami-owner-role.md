# 2026-11-28: AMI owner named by role in the meetings eval

## Why

#165's M5 gate on main 24a16f26 scored AMI 91, 89 and 89 (mean 89.7, floor
90.0). On one run the notes said "the note owner" where AMI's abstractive
summary, M5's reference, says "The Project Manager". `prepare.py` passed the
owner as "Speaker B", and #165's `Context.clean` correctly drops a label-shaped
owner name, so the notes had no name for the owner. The app was right; the eval
input was wrong.

## What changed

- `eval/meetings/prepare.py` names each AMI agent by its corpus role from
  `meetings.xml` (PM, ID, UI, ME → "Project Manager", "Industrial Designer",
  "User Interface Designer", "Marketing Expert"), the words the abstractive
  summaries use. The owner's role goes to `input.json` as `owner`, and the same
  names are the `speaker` values in `reference.json`.
- The scorer matches AMI speakers by overlap, not name, so M1–M4 are unchanged.
  No stored baseline holds AMI speaker names. `prepare.py` now rebuilds AMI
  folders on every run (about 12 s from its cached downloads) instead of
  skipping ones with a `reference.json`, so folders prepared before this change
  pick up the role names.

## Verification

`prepare.py --no-synthetic --ami ES2004a` (with `afconvert` stubbed on Linux)
writes owner "Project Manager" and reference speakers Project Manager 182,
Marketing Expert 164, Industrial Designer 123, User Interface Designer 80
segments. The role parse resolves all four agents for ES2004a–d, IS1009a and
TS3003a.
