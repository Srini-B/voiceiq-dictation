# Drop speech enhancement and Nemotron dictionary bias

Two local-dictation failures on the MacBook (VoiceiQ 0.5.19, Nemotron
real-time, English tools installed, 100-term dictionary) were traced to the
same two features.

An agent command came back as "On my contact sap, Ca Ca Ca Ca … Can Can Can
Cal Ref contact whose mobile number ends with 8475". FluidAudio 0.17.7's
`NemotronVocabularyBias` boosts every token that continues a dictionary term
by 4.5 log-prob, greedily, with no recovery. The dictionary term "Cal" made
"▁Ca" beat blank on every frame of a spoken hesitation. A TTS replay of the
sentence reproduced the loop with the user's dictionary or with "Cal" alone,
and decoded correctly without it. The loop persisted at per-term weight 3.0
and stopped at 2.5. A real recording in the eval below looped the same way on
"Ma" ("Make Ma Ma Ma … ×40") with "Maestro", "MCP", "macos", "macbook" in the
dictionary.

An 18-second dictation into Amp came back as "recent page and revocation …
in notation e voiced the dictations fail very bad". Replaying the saved
audio through the FluidAudio CLI: raw audio decoded "recent agent
invocation"; LocalVQE-enhanced audio decoded "age and invocation"; enhanced
audio plus the dictionary reproduced the app output exactly. The recording's
noise floor was −41 dBFS.

## Decision

- Remove LocalVQE from the English tools pack (revision v2, 17 files,
  103,865,880 bytes) and from both decoders. Neither Parakeet nor Nemotron
  enhances audio any more, in any mode. A v1 pack is cleared at launch and
  must be downloaded again.
- Stop passing dictionary terms to Nemotron's decoder. Parakeet keeps CTC
  rescoring from the pack. The dictionary still reaches the cleanup prompt
  and the deterministic replacement layer, so spelling of known terms is
  unchanged for cleaned text.
- The structural fix for the bias loop (a repeat or blank guard) belongs in
  FluidAudio. Lowering the weight to 2.5 and dropping short terms removed the
  loop on these clips but still cost 1.2 points of word error rate, so the
  bias was removed rather than tuned.

## Evidence

Fifteen MacBook recordings of the user (9 to 118 seconds, 9 with
`gpt-transcribe` and 6 with `gemini-3.5-transcribe` references) were replayed
on the Mac mini through the FluidAudio 0.17.7 CLI with the installed model
files. Word error rate against the stored cloud transcript:

| Decoder | Raw audio | Enhanced | Raw + dictionary | Enhanced + dictionary (shipped) |
|---|---:|---:|---:|---:|
| Nemotron 3.5 | 24.9% | 32.6% | 26.3% | 40.4% |
| Parakeet v3 | 14.9% | 21.2% | n/a | n/a |

Enhancement lost on 12 of 15 Nemotron recordings and 13 of 15 Parakeet
recordings. One clean 14-second command went from 0% to 36% on Parakeet and
18% to 55% on Nemotron. The dictionary bias never improved a Nemotron
recording by more than 4 points and caused two runaway loops. The cloud
references carry their own errors, so the absolute numbers are approximate;
the ordering held on every subset.

## Verification

- `VoiceIQCore` built with no warnings from the changed files; the release
  flow ran the test suite (143 passed) and produced a signed, notarized
  build (still numbered 0.5.19 at that point), which was installed on the
  MacBook over the previous copy. The change ships as 0.6.0, build 45.
- At launch the installed app cleared the v1 pack folder. The v2 pack was
  then placed with a script that mirrors `LocalModelInstaller.install`
  (staging folder, per-file size and SHA-256 check against the manifest,
  `.verified` marker, atomic rename); all 17 files matched. The in-app
  Download button was not pressed: the settings window's accessibility
  surface did not resolve for the automation driver, so that path is
  unverified on this machine.
- Replay through the installed helper
  (`VoiceiQ.app/Contents/Helpers/VoiceiQLocalSpeech.app`) with the user's
  100-term dictionary and the v2 tools folder, no microphone:
  - Dictation 20261010-164351 (18.3 s), Nemotron streaming and file modes:
    "Continuing from the South, take a look at the recent agent invocation
    that I did and take a look at the first dictation that I made on the
    agent in votation see voided the dictations fail very bad". Identical to
    the raw-audio FluidAudio CLI decode. The shipped build had produced
    "recent page and revocation … in notation e voiced".
  - TTS hesitation clip (9.1 s), both modes: "On my contacts app can you
    find the contact whose mobile number ends with eight thousand four
    hundred and seventy five". No "Ca Ca Ca" loop.
  - Eval clip 20261007-130749 (13.6 s), Parakeet file mode: "Alright, deploy
    the convex changes to development environment and production
    environment.", confidence 0.971, equal to the raw-audio CLI result.
  - Unified log: `Nemotron English: vad=true` and `Parakeet cold load
    complete … vad=true, vocabulary=true`, so both decoders found the v2
    pack; no enhancement line is emitted any more.
