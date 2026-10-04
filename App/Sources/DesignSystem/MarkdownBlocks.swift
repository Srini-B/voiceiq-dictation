import Foundation

/// The block structure of a Markdown answer, ready for a view to lay out.
///
/// `AttributedString(markdown:)` parses GFM fully but hands every block back
/// as a `presentationIntent` attribute on inline runs, with no line breaks.
/// Flattening that to one string put each table cell on its own line. This
/// groups the runs back into blocks so tables become grids, lists get their
/// markers, and code gets its box.
enum MarkdownBlock: Identifiable {
    /// One list item. Its content is a block sequence, so a nested list, a
    /// code block or a paragraph that resumes after the nested list keep
    /// their formatting and their source order.
    struct ListItem: Identifiable {
        let id: Int
        let ordered: Bool
        let ordinal: Int
        let blocks: [MarkdownBlock]
    }

    struct Table {
        let alignments: [PresentationIntent.TableColumn.Alignment]
        let header: [AttributedString]
        let rows: [[AttributedString]]
        var columnCount: Int { alignments.count }
    }

    case paragraph(id: Int, AttributedString)
    case heading(id: Int, level: Int, AttributedString)
    case list(id: Int, items: [ListItem])
    case code(id: Int, String)
    /// A quote is a block sequence like a list item, so a heading, list or
    /// code block inside it keeps its formatting.
    case quote(id: Int, [MarkdownBlock])
    case table(id: Int, Table)
    case rule(id: Int)

    var id: Int {
        switch self {
        case .paragraph(let id, _), .heading(let id, _, _), .list(let id, _),
             .code(let id, _), .quote(let id, _), .table(let id, _), .rule(let id):
            return id
        }
    }

    /// Inline text keeps `inlinePresentationIntent` (bold, code, strikethrough)
    /// and `link`; the view maps those to fonts. Block intents are stripped.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        guard let parsed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)) else {
            return [.paragraph(id: 0, AttributedString(markdown))]
        }
        return blocks(Array(parsed.runs), level: 0, in: parsed)
    }

    private typealias Run = AttributedString.Runs.Run

    /// The block component a run belongs to at `level`: 0 is the outermost
    /// block, 1 the block inside that, and so on. Components are stored
    /// innermost first.
    private static func component(of run: Run, level: Int) -> PresentationIntent.IntentType? {
        let components = run.presentationIntent?.components ?? []
        let index = components.count - 1 - level
        return components.indices.contains(index) ? components[index] : nil
    }

    /// Consecutive runs that share the block at `level` form one block.
    private static func grouped(_ runs: [Run], level: Int) -> [(id: Int, runs: [Run])] {
        var groups: [(id: Int, runs: [Run])] = []
        for run in runs {
            let id = component(of: run, level: level)?.identity ?? -1
            if groups.last?.id == id {
                groups[groups.count - 1].runs.append(run)
            } else {
                groups.append((id, [run]))
            }
        }
        return groups
    }

    private static func blocks(_ runs: [Run], level: Int, in source: AttributedString) -> [MarkdownBlock] {
        grouped(runs, level: level).map { build(id: $0.id, runs: $0.runs, level: level, in: source) }
    }

    private static func build(id: Int, runs: [Run], level: Int, in source: AttributedString) -> MarkdownBlock {
        switch component(of: runs[0], level: level)?.kind {
        case .none, .paragraph:
            return .paragraph(id: id, paragraphs(runs, in: source))
        case .header(let headingLevel):
            return .heading(id: id, level: headingLevel, paragraphs(runs, in: source))
        case .codeBlock:
            var text = runs.map { String(source[$0.range].characters) }.joined()
            while text.hasSuffix("\n") { text.removeLast() }
            return .code(id: id, text)
        case .blockQuote:
            return .quote(id: id, blocks(runs, level: level + 1, in: source))
        case .thematicBreak:
            return .rule(id: id)
        case .orderedList, .unorderedList:
            return .list(id: id, items: listItems(runs, level: level + 1, in: source))
        case .table(let columns):
            return .table(id: id, table(columns: columns, runs: runs, in: source))
        default:
            return .paragraph(id: id, paragraphs(runs, in: source))
        }
    }

    /// Inline text of the runs, with a line break between distinct paragraphs.
    private static func paragraphs(_ runs: [AttributedString.Runs.Run], in source: AttributedString) -> AttributedString {
        var out = AttributedString()
        var lastParagraph: Int?
        for run in runs {
            let paragraph = run.presentationIntent?.components.first { if case .paragraph = $0.kind { return true }; return false }?.identity
            if let lastParagraph, paragraph != lastParagraph { out.append(AttributedString("\n")) }
            lastParagraph = paragraph
            out.append(inline(run, in: source))
        }
        return out
    }

    private static func inline(_ run: AttributedString.Runs.Run, in source: AttributedString) -> AttributedString {
        var piece = AttributedString(source[run.range])
        piece.presentationIntent = nil
        return piece
    }

    /// `level` is the list item component; the list itself is one level out
    /// and decides the marker, since nested lists may mix numbers and
    /// bullets. The item's content is built one level in.
    private static func listItems(_ runs: [Run], level: Int, in source: AttributedString) -> [ListItem] {
        grouped(runs, level: level).compactMap { group in
            guard case .listItem(let ordinal) = component(of: group.runs[0], level: level)?.kind else { return nil }
            var ordered = false
            if case .orderedList = component(of: group.runs[0], level: level - 1)?.kind { ordered = true }
            return ListItem(id: group.id, ordered: ordered, ordinal: ordinal,
                            blocks: blocks(group.runs, level: level + 1, in: source))
        }
    }

    private static func table(columns: [PresentationIntent.TableColumn], runs: [AttributedString.Runs.Run], in source: AttributedString) -> Table {
        var header = Array(repeating: AttributedString(), count: columns.count)
        var rows: [[AttributedString]] = []
        var rowIndexByID: [Int: Int] = [:]
        for run in runs {
            let components = run.presentationIntent?.components ?? []
            var column: Int?
            var row: (id: Int, isHeader: Bool)?
            for component in components {
                switch component.kind {
                case .tableCell(let index): column = index
                case .tableHeaderRow: row = (component.identity, true)
                case .tableRow: row = (component.identity, false)
                default: break
                }
            }
            guard let column, let row, column < columns.count else { continue }
            let piece = inline(run, in: source)
            if row.isHeader {
                header[column].append(piece)
                continue
            }
            let rowIndex: Int
            if let known = rowIndexByID[row.id] {
                rowIndex = known
            } else {
                rowIndex = rows.count
                rowIndexByID[row.id] = rowIndex
                rows.append(Array(repeating: AttributedString(), count: columns.count))
            }
            rows[rowIndex][column].append(piece)
        }
        return Table(alignments: columns.map(\.alignment), header: header, rows: rows)
    }
}
