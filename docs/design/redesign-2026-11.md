# VoiceiQ design system (November 2026 redesign)

VoiceiQ is one calm app on the Mac and the iPhone. Every page is a white
canvas with ink type and hairline lists. The brand blue marks actions, and
red appears only while something records. This file is the contract for the
shared tokens in `VoiceIQCore/Sources/DesignSystem/VQ.swift`. The iPhone's
`Theme` and the Mac's `VoiceIQUI` read their values from those tokens.

It replaces the colour and type sections of `experience.md`. The motion
tokens (`VoiceIQMotion`) and the sound design in that file still apply.

## Direction

- **Layout and restraint.** These follow Voicenotes, on iPhone and on the web,
  and its Mac app for the Mac:
  - one large page title, a capsule search, and plain hairline lists grouped by
    day, with no cards;
  - a document-style detail page;
  - one dark action pill;
  - grouped cards only in Settings.
- **Gaps in that reference.** Other apps fill in only where Voicenotes has no
  matching screen:
  - Superwhisper, for the menu bar menu and the pill's key hints;
  - Wispr Flow, for the Dictionary page;
  - Granola and Superwhisper, for the Mac permission checklist.
- **VoiceiQ's own identity:**
  - Google Sans Flex, with light weights (300–350) for large titles;
  - the brand blue as the only accent;
  - the Talk key, a blue rounded square with the waveform mark that turns red
    while recording;
  - its own wording: "Written / What you said" and "Words to remember".

## Colour

| Token | Light | Dark | Use |
|---|---|---|---|
| canvas | #FFFFFF | #0F1012 | Page background |
| grouped | #F5F6F8 | #0F1012 | Settings pages, the Mac sidebar |
| surface | #FFFFFF | #1A1B1E | Cards on grouped pages, menus, sheets |
| fill | #EFF1F4 | #222428 | Search, switch tracks, selected row, chips |
| hairline | #E7E9ED | #2A2C31 | Rules between rows, rings |
| ink | #121419 | #F2F3F5 | Titles and body |
| ink2 | #3D414B | #C9CBD2 | Icons, secondary text that must read |
| muted | #6E727C | #8E929C | Meta, previews, captions |
| faint | #A2A6AF | #5D6169 | Placeholders and words still arriving only |
| accent | #2252BC | #7098F5 | Buttons, links, selection, the Talk key |
| accentSoft | #E8EEFB | #1B2540 | Wash behind a selected chip |
| onAccent | #FFFFFF | #0B1430 | Text on accent |
| record | #E5484D | #FF5F5F | Recording only |
| recordSoft | #FDE8E8 | #3A1A1B | Halo around the recording key |
| success | #1C8C52 | #4CC38A | Allowed, saved |
| warning | #B25E09 | #F0A44B | Needs attention |
| pill / onPill | #121419 / #F2F3F5 | same | The floating Mac pill, dark in both appearances |

## Type (Google Sans Flex)

| Style | iPhone | Mac | Use |
|---|---|---|---|
| display | 32 / 300 | 26 / 350 | Page titles |
| title | 26 / 300 | 22 / 350 | Dictation and meeting titles |
| title2 | 20 / 400 | 17 / 450 | Section titles inside a page |
| headline | 16 / 560 | 13.5 / 600 | Row titles, button labels |
| body | 16 / 400 | 14.5 / 400 | Dictation text, transcripts (1.5 line height) |
| callout | 15 / 400 | 13 / 400 | Settings rows, explanations |
| meta | 13 / 400 | 12 / 400 | Time, app, duration |
| caption | 12 / 500 | 11 / 500 | Day headings, group labels |

Sizes are size / variable weight. iPhone sizes scale with Dynamic Type.
Numbers use tabular figures.

## Spacing, radius, elevation

- **Spacing** is on a 4-point grid: 4, 8, 12, 16, 20, 24, 32 and 48. The page
  margin is 16 on the iPhone, the system layout margin that large titles and
  inset lists use, and 24 on the Mac.
- **Radius:**
  - Chips, search, switches and buttons are capsules.
  - Cards are 16. Sheets are 28.
  - Mac list selection is 10.
  - The Talk key is 20 on a 60-point square.
- **Elevation.** Pages are flat. Only floating things cast a shadow: the dock,
  the player, menus and the pill. Cards use a 1-point hairline ring instead.
- **Icons** are outline SF Symbols in `ink2`. Coloured icon tiles are not used.

## Components

| Component | Description |
|---|---|
| Page title | Display style, with an optional one-line muted summary below it. |
| Search capsule | Fill, with a magnifier and muted placeholder text. |
| Note row | Meta, then a title (headline, two lines), then a muted two-line preview. Below that sit a duration chip and a ⋯ button. A hairline runs below the row. |
| Day header | Caption style in muted text. |
| Duration chip | A capsule with a hairline ring. |
| Circle button | A 38-point circle on the iPhone, 30 points on the Mac. It has a hairline ring and one symbol. |
| Action pill | Ink for the main action (Copy, Share), accent for a setup step, fill for a secondary action. |
| Segment switch | Two options in a fill capsule. The selected option sits on canvas. |
| Grouped card | Settings only. Each row has an icon, a label, a muted value, and a chevron or a toggle. |
| Talk key | See [Direction](#direction). |
| Player capsule | Floats while audio plays. |
| Permission row | An icon, a title named for the benefit, and the reason it is needed. On the right is Allow, then Waiting…, then ✓ Allowed. |
| Key cap | A small fill rectangle for a shortcut. |
| Empty state | One line of muted text, with no illustration. |
