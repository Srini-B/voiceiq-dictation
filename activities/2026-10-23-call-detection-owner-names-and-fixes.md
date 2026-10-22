# Broader call detection, owner and Accessibility names, digit spacing, FluidVoice-inspired fixes

2026-10-23.

## Why

The user asked to finish the open items from the screen-names work (read
names through Accessibility, name the owner, fix digits glued to words), to
bring the iOS Notes screen in line where possible, to offer recording for
more kinds of calls (native VoIP apps, FaceTime, iPhone calls on the Mac),
and to adopt FluidVoice's improvements to existing dictation and meetings.

## Decisions

- **Call detection by behaviour, not only by list.** FluidVoice detects only
  Zoom, Teams, Webex and browser meetings. VoiceiQ now also offers when any
  app or browser page both captures the mic and plays sound, and when the
  system call daemons (`avconferenced`, `callservicesd`) capture the mic. A
  list of voice assistants, recorders and music apps is left out. The known
  list grew to Telegram, Signal, Viber, LINE, WeChat, Messenger, Chime, GoTo,
  RingCentral, Tencent Meeting, DingTalk, Around, Tuple and Element.
- **Browser pages by URL.** Taken from FluidVoice: read `AXURL` from the
  window's `AXWebArea`, not only window titles.
- **Owner named only from the call app's own marker** ("(me)", "(You)").
  Active-speaker views never show the user their own tile, so on-screen
  lift would name the owner after whoever spoke last.
- **Accessibility reading adds to OCR**, it does not replace it: exact
  spellings, and it works when the call window is covered.
- **Digits:** Fluid Speech Mini emits a space-only token before digits;
  `LocalMeetingJob.words` now starts a new word after it. The word cache is
  now `local-words-v2.json`, so Redo transcript re-decodes old meetings.
- **From the FluidVoice audit** (12 items checked): model downloads resume
  after a dropped connection; a provider word with no speaker joins the
  previous speaker instead of creating a phantom one; the meeting mic retries
  a failed device move and follows format changes on the same device; the
  cleanup gate rejects an answer to a dictated question. Not changed:
  dictionary misspellings as Parakeet vocabulary aliases (a documented
  design here, removed in FluidVoice), and re-pinning the insertion target
  when recording stops (changes insertion behaviour). The user chose to
  keep both as they are.
- **iOS Notes:** speaker colours, assign a speaker from known names, action
  items as "Owner: task", and an Export menu with Notes, Transcript, or both.
  No screen names on iOS.

## Verification

- Digits, on the installed notarized build with Redo transcript: GitLab
  meeting "May30th" → "May 30th"; AMI meeting 6 glued numbers → 0
  ("got 25", "or 12", "euros 50").
- Generic call rule: a scratch app capturing the mic and playing a tone,
  with an unknown bundle ID, raised the offer. It was first named after
  its launching terminal; apps capturing directly now win over owners. On
  the installed build the pill reads "Meeting in VoipSim — record it?".
- End to end on the installed build, Zoom meeting on screen, manual Record
  for 72 s: all 21 screen samples held "Cyron Test" with owner "Cyron Test";
  the meeting folder held no images. With the far side under 20 s of speech
  the call is treated as offline, so there is no "you" turn and no owner
  name (by design). With a two-track call (30 s far side on the system
  track, owner on the mic) Redo transcript gave the owner's turns the name
  "Cyron Test" (21 of 21 samples); the far speaker stayed "Speaker 1".
- iOS Notes on the simulator: coloured names, the owner's screen name, the
  speaker menu (known names, "Other name…"), action items, and the Export
  menu's share sheet with the Markdown file.
- Browser URL: `BrowserPages.read` on Chrome at `zoom.us/j/…` returned the
  meeting match "zoom.us" from the web area URL.
- Zoom 7.2.2 test meeting: `CallWindowText` read 22 lines in 0.03 s; names
  "Cyron Test", owner "Cyron Test" from "Cyron Test (me)".
- Download resume: a local server dropped the connection at 6 MB of 20 MB;
  the retry requested `bytes=6291456-` and the file's SHA-256 matched.
- Validation gate: existing tests pass; "What is the capital of France?" →
  "The capital of France is Paris." is rejected, cleanups of questions pass.
- Not tested live: FaceTime and relayed iPhone calls (would place a real call
  from the user's Apple ID), and multi-person Zoom, Meet and Teams calls.
