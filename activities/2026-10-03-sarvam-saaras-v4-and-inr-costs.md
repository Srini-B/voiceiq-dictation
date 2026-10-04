# Sarvam Saaras V4, rupee costs, and the ⌘-Tab abort

2026-10-03. Local, uncommitted at the time of writing.

## Why

Sarvam released Saaras V4 (speech-to-text for 22 Indian languages and English)
and prices it in rupees. The request: add it as a fourth transcription
provider, use Sarvam's text model for the writing pass, show costs in rupees as
well as dollars, and fix a dictation that cancels itself when the user
switches apps right after the hotkey.

## What was found before building

- Saaras V4 is speech-to-text only. The writing pass needs a chat model;
  Sarvam offers `sarvam-105b` on an OpenAI-shaped `/v1/chat/completions`.
  It takes text only, so the screenshot never reaches Sarvam. Gemini and the
  other providers keep theirs.
- `language_code=unknown` auto-detects and reports `language_probability`,
  so the Language picker defaults to "Detect automatically"; the 23 languages
  are there for when detection misses.
- The sync endpoint stops at 30 s. Longer audio and every diarized request go
  through the batch job flow (create → upload to Azure → start → poll →
  download). Diarization returns speaker turns, not words.
- Prices (docs, 2026-10-03): STT ₹30/hour, ₹45/hour with diarization;
  `sarvam-105b` ₹29.28 in, ₹10.98 cached, ₹73.20 out per million tokens.
- Translate, transliterate and language-id text APIs exist. Not built: the
  app has no place for them yet.

## Decisions

- The USD→INR rate comes from Frankfurter (ECB reference rate, free, no key).
  Each usage row stores the rate and the ECB date it came from, taken when the
  call is booked. A row booked without a rate (offline, or the cache older
  than 36 h) is back-filled later at its own day's rate, never at today's.
  Weekends and holidays use the last published day.
- Rupee costs are derived (`costUSD × fxRateINR`), not stored twice. A Sarvam
  row's rupee figure therefore equals the list price exactly (20 s → ₹0.1667).
- Historical rows were back-filled at each day's rate; the Cost pane's USD/INR
  toggle covers all history.
- Transcription provider: segmented control → menu, on Mac and iOS.
- Meetings on Sarvam use the diarized batch job; speaker turns feed the same
  `DiarizedWord` path the OpenAI diarizer uses.

## Follow-up: iOS parity and the writing-model default

- Picking Sarvam as transcription provider now defaults the writing model to
  Sarvam 105B. `SettingsStore.preferredWritingSource` derives the default from
  the transcription source when no `writingSource` key is stored; a stored
  choice wins whatever transcribes. The pickers show the derived value without
  writing it, so switching back to another provider restores the provider's
  model unless the user chose one.
- iOS Cost page gained the USD/INR toggle (same `costPaneCurrency` key) and the
  rupee footer; `AppModel` refreshes the rate and back-fills unrated rows at
  launch like the Mac controller. Compile-checked only; no simulator run.

## Review follow-up (PR #3 bot comments) and the iPad Settings header

Accepted:

- `sarvam-105b` chat now sends `max_tokens` (`Sarvam.outputBudget`: the
  prompt's character count, clamped to 4 096…32 768). The API default is
  2 048, which a long meeting's notes could exceed.
- A batch download that never reaches `COMPLETED` throws
  `network("sarvam_output_pending")`, so the recovery path retries it
  instead of treating it as a bad request.
- `UsageMeter` runs one FX refresh/back-fill at a time; `sarvamChat` no
  longer waits for the rate, it starts the refresh and lets the back-fill
  price the row.
- The cleanup prompt says "no images attached" when Sarvam writes, so the
  model is not told about screenshots it never receives.
- Batch polling starts at 3 s and treats a 429 as a wait, not a failure.
- Privacy pages (Mac and iOS) name Sarvam as the meeting-notes writer when
  it is the writing model.

Second round (on `6cdfe7d`):

- `max_tokens` is capped by plan (Starter 4 096, Pro 16 384, Business
  128 000). The budget stays; a 400 over the cap quotes the cap
  ("exceeds the maximum output length of N tokens") and `sarvamChat`
  retries once at N. Probed with the owner's key at 200 000 to read the
  message shape; the key itself allows 128 000, so the retry was not seen
  live.
- The batch output name comes from `job_details[].outputs[].file_name` in
  the completed status, with `0.json` as the fallback.
- Poll sleeps are bounded by the batch deadline (`pause`): a Retry-After
  longer than the time left throws `.timeout` instead of waiting it out.

Declined, with a reply on the thread:

- "+10 % for automatic language detection": the rate card lists ₹30/h and
  ₹45/h with no detection surcharge, and its FAQ's percentages do not match
  the card (45/30 is +50 %, not +20 %). The card stays the source. Check the
  Sarvam dashboard against the Cost pane after a few days of use.
- "Meetings with only a Sarvam key": the app requires a Gemini or OpenAI key
  as the provider; ElevenLabs and MAI have the same limit. Product decision,
  not changed here.

iPad Settings: the detail column showed a translucent bar with the section's
title over the content, and no row said which section was open.
`ListDetailNavigation` now removes the title and bar background from both
columns in regular width, paints the band under the tab bar with the canvas
colour, and `SettingsView` keeps a `SettingsSection` selection whose row is
tinted. Verified on the iPad Air 13" simulator (portrait, dark): no band, no
title, Dictation row tinted, Writing rules still pushes with a back button;
iPhone 17 simulator still pushes titled pages. Screenshots in
`.amp/in/artifacts/ipad-settings-dictation.png` and
`iphone-dictation.png` (not committed).

Third round (on `a377822`), all four accepted:

- `Retry-After` as an HTTP-date (`Fri, 03 Oct 2025 14:00:42 GMT`) is parsed
  by `GeminiClient.retryDelaySeconds`; seconds past now, floored at 0.
  Numeric values and the `retryDelay` body hint are unchanged.
- `sarvamTranscribe` and `sarvamDiarize` no longer wait for the FX refresh
  after the transcript is back; like `sarvamChat` they start it and let the
  back-fill price the row. A stale quote or an unreachable Frankfurter can no
  longer add its 10 s timeout to a dictation or meeting window.
- The batch poll loop backs off on 5xx the way it does on 429 (`sarvamGet`
  throws `.network("http_5xx")`, the loop pauses with the same 3 → 5 s
  ramp, bounded by the deadline). Before, a 503 on `/status` surfaced, and
  the retry queue uploaded a second job while the first kept running.
- A Sarvam row booked with no rate showed "—" and added nothing to the INR
  total until the back-fill. The row now stores `listINR` (migration
  `v4-listINR`, nullable column), the rate card's rupee price; the INR view
  and totals read `COALESCE(listINR, costUSD × fxRateINR)`. The rupee figure
  is exact at once; the dollar one still waits for the rate (`≈` on the USD
  total). Checked with a scratch test (not kept): ₹1.00 for 120 s of
  `saaras:v4` without a quote, totals and row agree, USD = 1/90 after a 90
  INR/USD back-fill. 148 package tests pass; Debug Mac build compiles.

## The ⌘-Tab abort

Report: tap the hotkey, switch apps within a second, dictation cancels. Code:
`EventTapEngine` fed every key-down inside the first second to the
accidental-chord abort. ⌘-Tab's Tab is such a key-down. Fix: only a key
pressed while the trigger modifier is still held counts as a chord. A key
after the release passes through and the session stays.

Reproduction on the installed build was blocked: a bare `fn` press cannot be
posted from this session (TCC denies the SSH process Accessibility, and
cua-driver posts to a pid, which the session tap does not see). The mechanism
is verified from code only. Manual check: tap `fn`, ⌘-Tab at once, speak, tap
`fn` again; the text should arrive in the second app.

## Bug found while verifying

The batch job-create call answers `202 Accepted`. The shared `post` treated
any non-200 as a transient network error and retried, so every dictation over
30 s on Sarvam (and every Sarvam meeting) queued forever. `post` now accepts a
2xx from Sarvam. The sync path was unaffected.

## Verification (installed, notarized 0.5.12 build)

- 148 core tests pass; Debug and iOS builds compile.
- 20 s recovered dictation on Sarvam: sync call 621 ms, language `en-IN`
  (p=1.00), transcript correct, usage row $0.00173 with rate 96.32 dated
  2026-10-02 (Saturday → last ECB day).
- Cost pane: USD and INR agree (₹3.20 = $0.0333 × 96.32); the Sarvam tab shows
  ₹0.1667 for the 20 s call. Historical rows carry their own day's rate
  (10-01 → 96.33, 10-02 → 96.32).
- Key validation, provider menu, language picker and writing-model picker
  checked on screen.
- After the 202 fix, rebuilt, notarized and reinstalled: an 81 s recovered
  dictation went through the batch job (about 5 s) and `sarvam-105b` cleanup;
  usage $0.00701 (= ₹0.675). A seeded two-speaker meeting (mic.caf and
  system.caf from two `say` voices, 32 s) came back as four turns, s1/s2 at
  the right boundaries, notes and action items from `sarvam-105b`; usage
  booked at ₹45/hour.
- Rows and recordings from these checks remain in History, Meetings and the
  usage database on the Mac mini. Delete them from the app if unwanted.

## Not done

- Translate, transliterate and language-id APIs (reported, no UI).
- Hotkey fix: code-level only; see above for the manual check.
