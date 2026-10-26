import AppKit
import SwiftUI
import VoiceIQCore

/// The dictionary manager: teach it your words once, they're spelled right forever.
/// Terms ride in the cleanup prompt; explicit misspelling rules are enforced
/// deterministically after every dictation.
struct DictionaryView: View {
    private let store = DictionaryStore()

    @State private var entries: [DictionaryEntry] = []
    @State private var newTerm = ""
    @State private var newMisspelling = ""
    @State private var search = ""
    /// Transient feedback under the add row / in the footer ("Already in your
    /// dictionary", "Imported 12 words") — silence on a failed action reads as
    /// a broken button.
    @State private var feedback: String?
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            addRow
            if entries.isEmpty {
                emptyState
            } else {
                entryList
            }
            footer
        }
        .onAppear(perform: reload)
        // Auto-learned words and entries synced from the iPhone arrive while
        // the pane is open.
        .onReceive(NotificationCenter.default.publisher(for: .gtDictionaryDidChange).receive(on: RunLoop.main)) { _ in reload() }
    }

    // Same field as History's header, so the two data panes share one header
    // shape and the window titlebar stays a plain title (a toolbar search field
    // restyled the titlebar and pushed the sidebar down on this pane only).
    private var searchRow: some View {
        HStack(spacing: VoiceIQUI.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search your dictionary", text: $search)
                .textFieldStyle(.plain)
                .font(VoiceIQUI.TypeScale.body(grad: grad))
        }
        .padding(.horizontal, VoiceIQUI.Spacing.s)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.small).fill(.quaternary.opacity(0.5)))
        .padding(.horizontal, VoiceIQUI.Spacing.l)
        .padding(.top, VoiceIQUI.Spacing.l)
    }

    private var addRow: some View {
        HStack(spacing: VoiceIQUI.Spacing.xs) {
            TextField("Add a word or phrase…", text: $newTerm)
                .textFieldStyle(.plain)
                .font(VoiceIQUI.TypeScale.body(grad: grad))
                .onSubmit(add)
            TextField("Heard as… (optional)", text: $newMisspelling)
                .textFieldStyle(.plain)
                .font(VoiceIQUI.TypeScale.body(grad: grad))
                .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                .onSubmit(add)
            Button(action: add) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(newTerm.isEmpty ? VoiceIQUI.Colors.onSurfaceVariant : VoiceIQUI.Colors.primary)
            }
            .buttonStyle(.plain)
            .disabled(newTerm.isEmpty)
        }
        .padding(VoiceIQUI.Spacing.s)
        .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(VoiceIQUI.Colors.surfaceContainer))
        .padding(.horizontal, VoiceIQUI.Spacing.l)
        .padding(.vertical, VoiceIQUI.Spacing.s)
    }

    private var filtered: [DictionaryEntry] {
        let base = entries.sorted {
            if $0.starred != $1.starred { return $0.starred }
            return $0.createdAt > $1.createdAt
        }
        let matching = search.isEmpty ? base : base.filter {
            $0.term.localizedCaseInsensitiveContains(search)
                || ($0.misspelling?.localizedCaseInsensitiveContains(search) ?? false)
        }
        return matching
    }

    private var entryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.l) {
                section("Dictionary", filtered.filter { $0.source == .manual })
                section("Auto-learned", filtered.filter { $0.source == .auto })
            }
            .padding(.horizontal, VoiceIQUI.Spacing.l)
            .padding(.vertical, VoiceIQUI.Spacing.s)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [DictionaryEntry]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xs) {
                Text(title)
                    .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: VoiceIQUI.Spacing.s)],
                          spacing: VoiceIQUI.Spacing.s) {
                    ForEach(items) { entry in entryCard(entry) }
                }
            }
        }
    }

    private func entryCard(_ entry: DictionaryEntry) -> some View {
        HStack(alignment: .top, spacing: VoiceIQUI.Spacing.s) {
            Button {
                store.toggleStar(id: entry.id)
                reload()
            } label: {
                Image(systemName: entry.starred ? "star.fill" : "star")
                    .foregroundStyle(entry.starred ? VoiceIQUI.Colors.gYellow : VoiceIQUI.Colors.onSurfaceVariant.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Starred words are prioritized")

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.term)
                    .font(VoiceIQUI.TypeScale.body(grad: grad))
                    .foregroundStyle(VoiceIQUI.Colors.onSurface)
                    .lineLimit(1)
                // A blank second line keeps cards without one the same height.
                Text(subtitle(entry) ?? " ")
                    .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                    .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                    .lineLimit(1)
            }
            .help([entry.term, subtitle(entry)].compactMap { $0 }.joined(separator: "\n"))
            Spacer(minLength: 0)
            Button {
                store.remove(id: entry.id)
                reload()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
            }
            .buttonStyle(.plain)
        }
        .padding(VoiceIQUI.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.medium).fill(VoiceIQUI.Colors.surfaceContainer))
    }

    private func subtitle(_ entry: DictionaryEntry) -> String? {
        if let misspelling = entry.misspelling, !misspelling.isEmpty { return "Heard as \"\(misspelling)\"" }
        if let learnedFrom = entry.learnedFrom, !learnedFrom.isEmpty { return "Heard as \"\(learnedFrom)\"" }
        return nil
    }

    private var emptyState: some View {
        VStack(spacing: VoiceIQUI.Spacing.s) {
            Spacer()
            Image(systemName: "character.book.closed")
                .font(.system(size: 28))
                .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
            Text("Teach it your words")
                .font(VoiceIQUI.TypeScale.title(grad: grad))
                .foregroundStyle(VoiceIQUI.Colors.onSurface)
            Text("Names, jargon, product terms — add them once,\nthey're spelled right in every dictation.")
                .font(VoiceIQUI.TypeScale.body(grad: grad))
                .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(feedback ?? "\(entries.count) \(entries.count == 1 ? "word" : "words")")
                .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(feedback == nil ? VoiceIQUI.Colors.onSurfaceVariant : VoiceIQUI.Colors.primary)
            Spacer()
            Button("Import CSV…", action: importCSV)
                .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
            Button("Export CSV…", action: exportCSV)
                .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                .disabled(entries.isEmpty)
        }
        .buttonStyle(.link)
        .padding(.horizontal, VoiceIQUI.Spacing.l)
        .padding(.vertical, VoiceIQUI.Spacing.s)
    }

    // MARK: - Actions

    private func add() {
        guard store.add(term: newTerm, misspelling: newMisspelling.isEmpty ? nil : newMisspelling) else {
            let trimmed = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            showFeedback(trimmed.count > 60 ? "Keep terms under 60 characters" : "Already in your dictionary")
            return
        }
        newTerm = ""
        newMisspelling = ""
        reload()
    }

    private func reload() {
        entries = store.entries()
    }

    private func showFeedback(_ message: String) {
        feedback = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            feedback = nil
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let csv = try? String(contentsOf: url, encoding: .utf8) else { return }
        let count = store.importCSV(csv)
        Log.ui.info("Dictionary: imported \(count) entries")
        reload()
        showFeedback(count == 0 ? "Nothing new to import" : "Imported \(count) \(count == 1 ? "word" : "words")")
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "voiceiq-dictionary.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportCSV().write(to: url, atomically: true, encoding: .utf8)
            showFeedback("Exported \(entries.count) \(entries.count == 1 ? "word" : "words")")
        } catch {
            Log.ui.error("Dictionary export failed: \(error)")
            showFeedback("Export failed — couldn't write the file")
        }
    }
}
