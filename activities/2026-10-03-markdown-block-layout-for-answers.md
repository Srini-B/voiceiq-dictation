# Agent and Ask Anything answers laid out block by block

2026-10-03. Not yet released.

## Why

An agent run on the MacBook (2026-10-03 21:05, `gpt-6-luna`, "Find me the
rate limits of Sarvam AI") answered with a GFM pipe table. The panel showed
every cell on its own line. The stored run confirms the model returned
Markdown; the renderer was the problem.

`MarkdownRenderer` (in `RichTextView.swift`) walked the runs of
`AttributedString(markdown:)` and inserted a line break whenever the block
identity changed. A table cell is a block, so a 5×4 table became 20 lines.
Lists, headings and code worked; tables had no path. The agent panel also
pushed that `NSAttributedString` through SwiftUI `Text`, which drops the
paragraph spacing it carried.

## What changed

- `App/Sources/DesignSystem/MarkdownBlocks.swift`: `MarkdownBlock` groups the
  parser's presentation intents into paragraph, heading, list (with nesting
  depth and ordered/unordered per item), code, quote, rule and table (column
  alignments, header, rows).
- `App/Sources/DesignSystem/MarkdownView.swift`: one SwiftUI view that lays
  those blocks out with the design tokens. Bold and inline code are set as
  explicit Google Sans faces because the variable font exposes no bold trait
  for SwiftUI's own mapping.
- `App/Sources/DesignSystem/MarkdownTableView.swift`: tables are a `Grid`
  with a tinted header row, hairline row dividers, per-column alignment and a
  rounded outline, inside a horizontal `ScrollView`. Column widths follow
  HTML auto layout (minimum = longest word, preferred = longest line capped
  at 320 pt, measured with AppKit). Fits → fill the panel; too wide → wrap the
  widest column first; still too wide → keep preferred widths and scroll the
  table alone. SwiftUI's `Grid` on its own reports no minimum width for text,
  so an 8-column table overflowed the panel and was clipped.
- `AgentEntryRow.answer` and `AnswerView` both use `MarkdownView`. The saved
  runs in Settings → Agent (`AgentRunsPane`) draw `AgentEntryRow`, so history
  gets the same layout with no further change. `MarkdownRenderer` is deleted.
  `RichTextView` stays for the meeting transcript, which is plain text.

PR #4 review (Codex, CodeRabbit) found three defects, all fixed in the
follow-up commit:

- A bold span inside a heading dropped to body size, because `styled` swapped
  in a body-sized bold font. `styled` and `measured` now take a size and a
  weight and build the font per run, so bold only raises the weight.
- A list item whose text resumed after its nested list was pulled up in front
  of the nested items, because runs were bucketed by item identity. A second
  round found the related flaw: a code block, quote or table inside a list
  item lost its formatting, because every item was reduced to one string.
  `ListItem` now holds `[MarkdownBlock]`; the parser groups runs by the block
  component at each nesting level and recurses into items, and
  `MarkdownBlocksView` renders an item's blocks under its marker. Source order
  and block formatting follow from the structure instead of special cases.
  A third round asked for the same inside block quotes; `.quote` now holds
  `[MarkdownBlock]` too.
- A table cell holding one word longer than the 320 pt cap got a preferred
  width below its minimum and clipped instead of scrolling. Preferred width is
  now clamped to at least the minimum.

Chosen over `NSTextTable` inside the existing `NSTextView`: that needs a
TextKit 1 fallback, a self-sizing text view for the agent row, and gives no
control over table styling.

## Verification

- Release flow `SKIP_TESTS=1 scripts/release.sh` built, signed and notarized
  0.5.13 (38, first version) and again after the table work; installed to
  `/Applications` on the Mac mini and launched.
- Offscreen harness (`.amp/in/harness`, not committed) compiled the
  production `MarkdownBlocks`, `MarkdownView`, `MarkdownTableView` and
  `DesignTokens` with the bundled fonts and rendered the stored Sarvam answer,
  a sample with headings, nested lists, quote, code block, aligned table and
  link, and an 8-column table, in light and dark appearance, at the panel's
  524 pt content width. The 4-column Sarvam table wrapped only its first
  column. The 8-column table measured 808 pt, clipped inside its frame, and
  scrolled to its last column when the harness scrolled its `NSScrollView`
  while the paragraph above it stayed in place.
- Not exercised: a live agent run or Ask Anything round-trip in the installed
  build. The `voiceiq://agent/<command>` hook is DEBUG-only and AGENTS.md
  requires testing on the notarized build, so the next real run on the
  MacBook is the end-to-end check.
