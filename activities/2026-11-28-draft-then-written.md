# 2026-11-28: The transcript goes in as a draft, then the written text replaces it

## Why

cyron asked for the behaviour of the dictation app ranked first on Voice
Arena's Dictation Bench: the raw transcript appears in the field at once,
underlined, a processing animation runs while the writer rewrites it, and
the written text then replaces exactly the pasted text, with a spinner in
the field before the transcript lands. With several dictations into one
field, each replaces only its own text; earlier dictations and anything
typed stay as they are.

The earlier "not possible" was a design rule, not a measured limit:
`product-reliability.md` §5.3 ("insert once, at the end — retro-replacement
is clipboard-racy") and the `TranscriptValidator` note ("never retro-replace
pasted text"), both from the Gemini batch design (2026-08-17). Then there
was no transcript before the one model call returned, and a replacement
would have been a blind clipboard edit. Since 0.7.19 (PR #121) STT-3.7
Realtime has the transcript at key-up and the writer adds about 1 s, and
the swap is an Accessibility selection of exactly the draft's range, read
back before anything is written.

## Research

- Voice Arena Dictation Bench (voicearena.com/dictation-bench, read
  2026-11-28): 1. Function Voice 1 (ZER 82.74), 2. Aqua Voice (80.50),
  3. Wispr Flow (79.31). Function has no Mac app; Voice Arena ran its model
  through a harness. Function's iPhone keyboard shipped the behaviour in beta
  build 304 ("Your words go in as soon as you tap the check mark, and the
  cleaned-up text takes their place when it's ready"); its founder describes
  "optimistically showing the transcription early" with an "ascii loader".
  Nothing public says how its keyboard swaps the text.
- AGIHunt/blurt (MIT, macOS) replaces an already-pasted dictation by setting
  `kAXSelectedTextRange`, reading it back, then ⌘V; it refuses when focus
  moved. VoiceiQ uses the same verified-selection idea with its own code.
- Reported pitfalls in other apps: duplicate text after an Accessibility
  write whose read-back was stale (then a ⌘V fallback), Chromium fields that
  hide from Accessibility or accept a write and drop it, clipboard races.
  These shaped `FieldDraft`: Chromium/Electron swaps go select-then-⌘V only,
  and a ⌘V goes only to the focused field while the selection is still
  exactly the draft.

## What changed

- Core: `TextInserting.draft(context:)`, `TextDraft`, `DraftShown`;
  `transcribe(…, onHeard:)`; `DraftStage`; `InsertTurns` gains a `placed`
  gate; `DictationCoordinator.writingDraft`.
- `DraftLedger` (Bridge): every draft in a field followed through each
  change. Each dictation swaps only its own range; the text is never
  searched for.
- Mac: `FieldDraft` and `DraftField` (Accessibility), `DraftOverlay`
  (spinner and shimmer underline), `WaveformView(writing:)`.
- iPhone: the keyboard types the draft as marked text (hosts underline it)
  only in the input session Stop was tapped in, and only when it could swap
  it later (single-code-point characters, no line break, at most 200
  characters). The swap commits it and retypes it while it sits right
  before the cursor with the same text around it; otherwise it stays. The strip shows a writing crest. No
  spinner in the field: a host commits marked text when focus moves, which
  could leave a spinner glyph in the user's text.
- Docs: `architecture.md` ("Draft, then the written text"), `IOS.md` ("The
  transcript as a draft"), `product-reliability.md` §5.3 marked superseded.

## Where it falls back to one paste

Terminals (`AppQuirks.forcePaste`), typed-in apps (`TypingInserter`), fields
Accessibility can't read (Google Docs' canvas), fields over 20,000 UTF-16
units, secure input, Press Return after paste, focus outside the field the
dictation started in, an app whose field once never showed a posted draft
(until restart), on-device transcription, no AssemblyAI key. On iPhone: any
field other than the input session Stop was tapped in, and transcripts the
keyboard could not swap (Tamil and Devanagari, line breaks, over 200
characters).

## Review rounds

Hand review on BlueLobster (each head), Codex (six findings, all fixed),
Fable 5.2 (78/100 at 390def9: four Mediums, fixed in the next head; 88/100
at 089351d with no High or Medium, short of 90 for want of device proof;
87/100 at 98edb9b: a ⌘V-only field keeps its draft on Esc or no speech
silently, now announced on the pill rather than removed by a posted Delete). Main
changes from review: the selection read-back checks the whole value and is
polled; a posted draft is never followed by the written text beside it; an
accepted Accessibility write never falls back to ⌘V; the swap method follows
how the draft went in; a draft beside an identical copy of its text is
dropped on an ambiguous edit (`FieldEdit.earliest`); Esc or a failure takes
the Mac draft back out (by Accessibility only: a posted Delete could eat a
key typed meanwhile, so a ⌘V-only field keeps the draft); iPhone never sets
marked text over a draft.

## Verification

Filled in below as each check finishes.

- Mac mini harness (the real `FieldDraft` against an NSTextView and a
  Safari textarea, e1e0a67–23b2177): show, swap, overlap and edit
  scenarios correct in NSTextView. Safari took the selection, answered the
  `kAXSelectedText` write with success and never changed the text in
  1.4 s, so the swap kept the raw text. Fields under an `AXWebArea` now
  swap by ⌘V. The overlay panels exist on screen (floating level) but are
  left out of screen captures while "Hide from screen sharing" is on, the
  default. The spinner sat one line high at the end of an NSTextView, from
  the empty-range bounds; it now uses the character before the caret.
- Mac mini at 183c620: KeyboardTests 21/21 (including the five deleted- and
  repeated-context cases), `swift test` 334 passed (1 skipped), VoiceIQ and
  VoiceIQiOS xcodebuild exit 0. b34b757's app build failed on an internal
  `withdrawKeptNotice`; 183c620 made it public.
- Harness at b34b757 (the Mac code of 183c620 bar that one keyword): in
  NSTextView, plain, multi-line, typed-before, caret-moved and two
  overlapping dictations swap correctly; an edited or deleted draft is kept.
  Safari textarea: the ⌘V swap now lands ("…See you at three" → "…See you at
  3."). TextEdit: swap lands with the spinner on the caret's line; Esc takes
  the draft out and leaves the field as before.
- Not verified on device: typing or a focus change while the writer runs
  (the harness's posted events didn't reach the app), Chrome (its textarea
  was not readable by Accessibility from the harness), Electron, and the
  iPhone keyboard flow, which KeyboardTests cover with a fake proxy. The demo
  recordings on the signed build cover the TextEdit and iPhone flows.
- Mac video at 0c95320 (signed, installed, speech from WAV files through
  `DebugDictationAudioFiles`): the spinner, the underlined raw text with the
  writing waveform, the swap, then typed text and a second dictation where
  only the newest is replaced. The real writer answered both.
- iPhone, Messages in the simulator: the second dictation's swap wiped the
  earlier dictation and the typed text, while the keyboard's own view of the
  field read the expected result. iPhone drafts are switched off
  (`KeyboardInserter.offersDrafts`) until a host-safe swap exists. That
  swap, and drafts back on in Messages and VoiceiQ:
  `2026-11-28-iphone-draft-swap-by-insert.md`.
- cyron's report: in a full single-line field the marks drew outside the
  field and the inserted text stayed hidden past its edge. Marks are now cut
  to the field's visible frame, and `ScrollToCaret` brings the caret into
  view after an Accessibility insert.
- Field cases on the signed build of 596c6cf (Mac code as at 54724e7;
  `swift test` 340 passed, 1 skipped), speech from a WAV through the real
  writer, which removed the "um" each time:
  - TextEdit Save As field with 65 characters already in it: the spinner
    showed at the caret inside the field, the field scrolled to the end of
    the raw text, the underline stayed inside it, and the swap kept the prefix
    (log: "caret brought into view by setting it again").
  - 60-line TextEdit document, caret at the bottom edge: the view scrolled 2
    lines, all three wrapped raw lines were underlined inside the view, and
    the swap was correct.
  - Chrome single-line `<input>` filled past its width: no draft (it is
    under an `AXWebArea`), one ⌘V paste of the written text, and Chrome
    scrolled the input itself.
  - VS Code search box (a wrapping textarea): the Accessibility write was
    ignored, so the draft went in by ⌘V. The box grew, the draft was
    underlined, and the swap kept the prefix. The underline lies on the
    box's bottom border, a little past the last word, within the box.
  - Empty TextEdit document: no spinner shows (before, it appeared at the
    window corner), then the underline and swap as usual.
  - Typing benchmark, TextEdit: 1,000 characters with quotes and "...",
    posted in 100 events, landed exactly in 125 ms. In a plain-text
    document no autocorrect or smart quotes were applied. Chrome was not
    measured.
