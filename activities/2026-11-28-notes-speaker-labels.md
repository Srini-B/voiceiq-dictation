# Speaker labels in meeting notes (2026-11-28)

**Seen:** in the M5 recheck on 7c093593, the ES2004a notes for the AMI meeting
wrote a raw speaker label in 2 of 6 runs, against 0 of 15 earlier. m5main-1 had
"Speaker B presumed this was for the first year…" and m5re-1 had "Speaker 4
noted that the company website says…".

**Cause, from the runs' output files:**
- "Speaker B" is the owner's name in the AMI eval. `eval/meetings/prepare.py`
  names AMI's anonymous agents "Speaker A…D" and passes the owner's label as
  `owner`, and the notes prompt treated it as a confirmed name. Real meetings
  never give the owner a label-shaped name, but a screen tag or a typed name
  could.
- "Speaker 4" is the model breaking the prompt's own rule ("Never write a
  label such as 'Speaker 3' outside 'speakers'"). It happened once in 6 runs,
  and the transcript and labels were identical in all six.

**Change:**
- A label-shaped owner name counts as no name, so the owner is "Note owner".
- After parsing, any label left in the notes text becomes the name the model
  gave that label in "speakers", or "another participant". An action owner
  that is a label becomes that name, or nil.
