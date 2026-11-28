# 2026-11-28 — Redesign, step 1: shared design tokens

## Why

The Mac and iPhone apps had two separate design systems: Material-style
colours on the Mac (`VoiceIQUI`) and a blue-on-porcelain set on the iPhone
(`Theme`). The full redesign starts with one shared token set, so both apps
change together and later screen work only changes layout.

## Changes

- New `VoiceIQCore/Sources/DesignSystem/VQ.swift`: colours (light and dark),
  spacing, radius and the type scale, with Mac and iPhone sizes.
- `Theme` (iPhone) and `VoiceIQUI` (Mac) now read their colours from `VQ`.
  The display and title sizes come from `VQ.TypeScale`.
- iPhone cards lose their drop shadows and keep a 1-point hairline ring.
- Spec: `docs/design/redesign-2026-11.md`. `experience.md` points to it for
  colour and type.

## Decisions

- **References.** Voicenotes is the reference for every screen. Its Mac app
  (2.0) is the reference for the Mac. Other apps are used only where
  Voicenotes has no matching screen.
- **VoiceiQ's own identity.** VoiceiQ keeps Google Sans Flex, its blue and
  its own Talk key, so the apps do not read as a copy.
- **Pill colours.** The Google four-colour waveform tokens stay for now. The
  pill is restyled in its own step, after the meeting pill work lands.
