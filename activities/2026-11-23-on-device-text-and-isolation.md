# Numbers, sound-alike spellings and voice isolation from Hex

**2026-11-23.** cyron picked three items from the daily Hex check: numbers as
digits and Dictionary sound-alike spellings for on-device dictation with
writing Off, and voice isolation for dictation. Hex is MIT; the code and test
cases are adapted with its notice (`THIRD_PARTY_NOTICES.md`). Hex reviewed at
`db515bda` (unchanged baseline for the daily watch; FluidVoice `87fbef8b`).

## Why

- **Numbers.** Fluid Speech English output ran FluidAudio's NeMo inverse
  normalization. On Hex's 110 number cases it matched 32: it wrote "Between 15
  minutes" for "Between five and ten minutes", "14:50 %" for "Ten to fifteen
  percent", "I work 04:51" for "I work nine to five", "No 1 came" for "No one
  came". Hex's `SpokenNumbers` passes all 110, as it should on its own cases.
  First it replaced NeMo only with writing Off. After seeing the NeMo errors,
  cyron asked for the writers to get it too, on Mac and iPhone, so it now
  replaces NeMo everywhere and the `NemoTextProcessing` trait is dropped. The
  Gemini request, prompt and hedging are unchanged; only the numbers in the
  transcript Gemini is given change.
- **Sound-alike spellings.** Speech models write a name's commonest spelling,
  so a Dictionary term spelled another way ("Stacey") never matched.
- **Voice isolation.** Ships as a setting, off by default, for the reasons in
  `docs/design/architecture.md` (Hex's Labs status, level change against the
  no-speech gate, ducking, Bluetooth call profile).

## Verification

- `swift test --package-path VoiceIQCore` on a cloud Mac (macOS 27,
  Xcode 27.3 beta 2): 190 tests, 0 failures, including Hex's ported cases.
- Mac and iOS Simulator app builds succeeded.
- `AudioCaptureEngine` with voice isolation on recorded through voice
  processing (4-channel processed input, ~24,600 frames in 1.5 s, cold and
  prewarmed) on the cloud Mac's virtual input; with it off it recorded raw.
  Not tried on a real microphone, AirPods or an iPhone.
- iOS Settings › Dictation shows the toggle (screenshots in the PR).
- Review (Codex): Hex's iOS voice isolation only sets the `.voiceChat` mode,
  which by itself applies no voice processing, so the iPhone capture engine
  now turns voice processing on as the Mac's does. Not run on an iPhone.
  Also fixed a `SpokenNumbers` case Hex gets wrong: "twenty Five Guys" with
  "Five Guys" in the Dictionary became "25 Guys"; the number now stops at a
  protected term.

## Rollback

Revert the PR. Voice isolation is off unless the user turns it on; turning it
off returns capture to the previous graph.
