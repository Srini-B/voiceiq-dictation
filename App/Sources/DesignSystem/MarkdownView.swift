import AppKit
import SwiftUI

/// Lays out a Markdown answer block by block: paragraphs, headings, lists
/// with markers, code in a box, quotes with a bar, and tables as a grid.
/// Shared by the agent panel and the Ask Anything answer.
struct MarkdownView: View {
    private let blocks: [MarkdownBlock]
    private let style: MarkdownStyle
    private let color: Color
    private var size: CGFloat { style.size }

    init(_ markdown: String, size: CGFloat = 14, color: Color = VoiceIQUI.Colors.onSurface) {
        blocks = MarkdownBlock.parse(markdown)
        style = MarkdownStyle(size: size)
        self.color = color
    }

    var body: some View {
        MarkdownBlocksView(blocks: blocks, style: style, spacing: size * 0.6)
            .foregroundStyle(color)
            .textSelection(.enabled)
    }
}

/// A block sequence. The top level of an answer and the content of each list
/// item are both one of these, so lists nest to any depth.
private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let style: MarkdownStyle
    let spacing: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block, style: style)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let style: MarkdownStyle
    private var size: CGFloat { style.size }

    var body: some View {
        switch block {
        case .paragraph(_, let text):
            inline(text)
        case .heading(_, let level, let text):
            Text(style.styled(text, size: headingSize(level), weight: MarkdownStyle.bold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, size * 0.3)
        case .list(_, let items):
            list(items)
        case .code(_, let code):
            Text(code)
                .font(style.code)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VoiceIQUI.Colors.surfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.small, style: .continuous))
        case .quote(_, let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(VoiceIQUI.Colors.outlineVariant)
                    .frame(width: 3)
                MarkdownBlocksView(blocks: blocks, style: style, spacing: size * 0.3)
                    .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(_, let table):
            MarkdownTableView(table: table, style: style)
        case .rule:
            Divider()
        }
    }

    // MARK: - Inline

    private func inline(_ text: AttributedString) -> some View {
        Text(style.styled(text))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return size * 1.3
        case 2: return size * 1.15
        default: return size
        }
    }

    // MARK: - Lists

    private func list(_ items: [MarkdownBlock.ListItem]) -> some View {
        VStack(alignment: .leading, spacing: size * 0.3) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.ordered ? "\(item.ordinal)." : "•")
                        .font(style.body)
                        .frame(minWidth: 16, alignment: .trailing)
                    MarkdownBlocksView(blocks: item.blocks, style: style, spacing: size * 0.3)
                }
            }
        }
    }
}

/// Fonts for one answer. Bold and code come through as
/// `inlinePresentationIntent`; SwiftUI's own mapping would ask the variable
/// font for a bold trait it does not expose, so the faces are set explicitly.
struct MarkdownStyle {
    let size: CGFloat
    static let regular: CGFloat = 400
    static let bold: CGFloat = 600

    var body: Font { GTFont.flex(size, weight: Self.regular) }
    var code: Font { GTFont.sansCode(size - 1, weight: Self.regular) }

    /// Sets a font on every run from its inline intent. Bold raises the weight
    /// and code switches family; both keep the block's `size`, so a bold span
    /// inside a heading stays heading-sized.
    func styled(_ text: AttributedString, size: CGFloat? = nil, weight: CGFloat = MarkdownStyle.regular) -> AttributedString {
        let size = size ?? self.size
        var out = text
        for run in out.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = GTFont.flex(size, weight: intent.contains(.stronglyEmphasized) ? Self.bold : weight)
            if intent.contains(.code) { font = GTFont.sansCode(size - 1, weight: Self.regular) }
            if intent.contains(.emphasized) { font = font.italic() }
            out[run.range].font = font
            out[run.range].inlinePresentationIntent = nil
            if intent.contains(.strikethrough) { out[run.range].strikethroughStyle = .single }
        }
        return out
    }

    /// The same text as AppKit measures it, for column sizing.
    func measured(_ text: AttributedString, weight: CGFloat = MarkdownStyle.regular) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = GTFont.nsFlex(size, weight: intent.contains(.stronglyEmphasized) ? Self.bold : weight)
            if intent.contains(.code) { font = GTFont.nsSansCode(size - 1, weight: Self.regular) }
            out.append(NSAttributedString(string: String(text[run.range].characters), attributes: [.font: font]))
        }
        return out
    }
}
