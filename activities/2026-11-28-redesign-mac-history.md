# 2026-11-28 — Redesign, step 4: Mac sidebar and History

## Changes

- **Sidebar.** The sidebar uses outline symbols in the secondary ink, with no
  coloured tiles. The selected row is a quiet grey fill with ink text instead
  of the blue selection. `VoiceIQUI.Colors.selection` and `onSelection` are
  removed.
- **History list.** The list opens with a "History" title and one muted line
  of totals. The streak, audio and count are in its tooltip, and the period
  menu sits beside it. The search is a capsule. Each row shows its time, app,
  length and cost first, then two lines of text. The empty state loses the
  four-colour bars.
- **Dictation page.**
  - The page has no rule under its header. The header is a muted meta line
    with the actions: play and download, retry, delete, and Copy as the ink
    pill.
  - When the written text differs from what was heard, a "Written / What you
    said" switch picks between them.
  - The details sit under a captioned hairline.
- **Shared pieces.** `App/Sources/DesignSystem/Components.swift` adds
  `InkPillButtonStyle` and `SectionCaption`.

## Reference

Voicenotes for Mac 2.0: a quiet sidebar, and the same list and reading page
as the iPhone.
