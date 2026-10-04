import AppKit
import SwiftUI

/// A Markdown table as a grid with a header row, hairline row dividers and
/// per-column alignment.
///
/// Column widths follow HTML's automatic table layout. Each column has a
/// minimum width (its longest word) and a preferred width (its longest line,
/// capped so prose wraps). When the preferred widths fit the panel, the table
/// fills it. When only the minimums fit, columns wrap. When even the minimums
/// do not fit, the table keeps its preferred widths and scrolls sideways on
/// its own. SwiftUI's `Grid` cannot do this by itself: it reports no minimum
/// width for text, so too many columns overflowed and were clipped.
struct MarkdownTableView: View {
    let table: MarkdownBlock.Table
    let style: MarkdownStyle

    @State private var availableWidth: CGFloat = 0

    private static let horizontalPadding: CGFloat = 10
    private static let verticalPadding: CGFloat = 6
    private static let preferredCap: CGFloat = 320

    var body: some View {
        let widths = columnWidths()
        ScrollView(.horizontal) {
            grid(widths: widths)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .clipShape(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiceIQUI.Radius.small, style: .continuous)
                .stroke(VoiceIQUI.Colors.outlineVariant, lineWidth: 1)
        )
        .background(GeometryReader { proxy in
            Color.clear.preference(key: WidthKey.self, value: proxy.size.width)
        })
        .onPreferenceChange(WidthKey.self) { availableWidth = $0 }
    }

    private func grid(widths: [CGFloat]) -> some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<table.columnCount, id: \.self) { column in
                    cell(table.header[column], column: column, width: widths[column], weight: MarkdownStyle.bold)
                }
            }
            .background(VoiceIQUI.Colors.surfaceContainer)
            ForEach(0..<table.rows.count, id: \.self) { row in
                Divider().gridCellColumns(table.columnCount)
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(table.rows[row][column], column: column, width: widths[column], weight: MarkdownStyle.regular)
                    }
                }
            }
        }
    }

    private func cell(_ text: AttributedString, column: Int, width: CGFloat, weight: CGFloat) -> some View {
        let alignment = Alignment(horizontal: horizontalAlignment(column), vertical: .top)
        return Text(style.styled(text, weight: weight))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width - 2 * Self.horizontalPadding, alignment: alignment)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .frame(maxHeight: .infinity, alignment: alignment)
    }

    private func horizontalAlignment(_ column: Int) -> HorizontalAlignment {
        switch table.alignments[column] {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }

    // MARK: - Column sizing

    private struct ColumnBounds {
        var minimum: CGFloat = 0
        var preferred: CGFloat = 0
    }

    private func columnWidths() -> [CGFloat] {
        var bounds = Array(repeating: ColumnBounds(), count: table.columnCount)
        for column in 0..<table.columnCount {
            measure(table.header[column], weight: MarkdownStyle.bold, into: &bounds[column])
            for row in table.rows { measure(row[column], weight: MarkdownStyle.regular, into: &bounds[column]) }
        }
        // A single word longer than the cap (a URL, an identifier) must still
        // get its minimum, or the table would clip it instead of scrolling.
        let minimums = bounds.map { $0.minimum + 2 * Self.horizontalPadding }
        let preferreds = bounds.map { max($0.minimum, min($0.preferred, Self.preferredCap)) + 2 * Self.horizontalPadding }
        let minimumSum = minimums.reduce(0, +)
        let preferredSum = preferreds.reduce(0, +)

        guard availableWidth > 0, minimumSum <= availableWidth else { return preferreds }
        if preferredSum <= availableWidth {
            let extra = availableWidth - preferredSum
            return preferreds.map { $0 + extra * $0 / preferredSum }
        }
        // Wrap the widest column first, down to its minimum, then the next.
        // Narrow columns (numbers, short labels) stay on one line.
        var widths = preferreds
        var deficit = preferredSum - availableWidth
        for column in widths.indices.sorted(by: { widths[$0] > widths[$1] }) where deficit > 0 {
            let shrink = min(deficit, widths[column] - minimums[column])
            widths[column] -= shrink
            deficit -= shrink
        }
        return widths
    }

    /// The longest word sets the minimum; the longest line sets the preferred
    /// width. A point of slack keeps SwiftUI's own rounding from wrapping a
    /// word AppKit measured as fitting.
    private func measure(_ text: AttributedString, weight: CGFloat, into bounds: inout ColumnBounds) {
        let measured = style.measured(text, weight: weight)
        for range in Self.ranges(in: measured.string, separatedBy: .newlines) {
            bounds.preferred = max(bounds.preferred, measured.attributedSubstring(from: range).size().width + 1)
        }
        for range in Self.ranges(in: measured.string, separatedBy: .whitespacesAndNewlines) {
            bounds.minimum = max(bounds.minimum, measured.attributedSubstring(from: range).size().width + 1)
        }
    }

    private static func ranges(in string: String, separatedBy separators: CharacterSet) -> [NSRange] {
        let string = string as NSString
        var ranges: [NSRange] = []
        var start = 0
        while start < string.length {
            let remaining = NSRange(location: start, length: string.length - start)
            let separator = string.rangeOfCharacter(from: separators, options: [], range: remaining)
            let end = separator.location == NSNotFound ? string.length : separator.location
            if end > start { ranges.append(NSRange(location: start, length: end - start)) }
            start = separator.location == NSNotFound ? string.length : separator.location + separator.length
        }
        return ranges
    }

    private struct WidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}
