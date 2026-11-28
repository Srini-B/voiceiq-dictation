import AppKit
import SwiftUI
import VoiceIQCore

/// The dictionary manager: teach it your words once, they're spelled right forever.
/// Terms ride in the cleanup prompt; explicit misspelling rules are enforced
/// deterministically after every dictation.
struct DictionaryView: View {
    /// Set by the menu bar's Add to Dictionary…; the pane puts the cursor in
    /// the add row and clears it.
    @Binding var addWordRequested: Bool
    private let store = DictionaryStore()

    @State private var entries: [DictionaryEntry] = []
    @State private var newTerm = ""
    @State private var newMisspelling = ""
    @State private var search = ""
    @FocusState private var focusedField: AddField?
    private enum AddField { case term, heardAs }
    /// Transient feedback under the add row / in the footer ("Already in your
    /// dictionary", "Imported 12 words") — silence on a failed action reads as
    /// a broken button.
    @State private var feedback: String?
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Dictionary", subtitle: "Names and terms VoiceiQ should always spell your way.")
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
        .task(id: addWordRequested) {
            guard addWordRequested else { return }
            focusedField = .term
            addWordRequested = false
        }
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
                .foregroundStyle(VQ.Colors.muted)
            TextField("Search your dictionary", text: $search)
                .textFieldStyle(.plain)
                .font(VoiceIQUI.TypeScale.body(grad: grad))
        }
        .padding(.horizontal, VoiceIQUI.Spacing.s)
        .frame(height: 32)
        .background(Capsule().fill(VQ.Colors.fill))
        .padding(.horizontal, VQ.Spacing.page)
    }

    /// The labels stay above the fields once they are filled in, so the right
    /// spelling and the misheard one can't be typed into each other's field
    /// (Hex labels its two columns for the same reason, anomalyco/hex, MIT).
    private var addRow: some View {
        HStack(alignment: .bottom, spacing: VoiceIQUI.Spacing.xs) {
            labeledField("Write it as", example: "e.g. Kubernetes", text: $newTerm, field: .term)
            labeledField("Heard as (optional)", example: "e.g. cooper netties", text: $newMisspelling, field: .heardAs)
            Button(action: add) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(VQ.Colors.accent)
                    .opacity(newTerm.isEmpty ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .help("Add to your dictionary")
            .disabled(newTerm.isEmpty)
        }
        .padding(.horizontal, VoiceIQUI.Spacing.m)
        .padding(.vertical, VoiceIQUI.Spacing.s)
        .background(RoundedRectangle(cornerRadius: VQ.Radius.card, style: .continuous).fill(VQ.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: VQ.Radius.card, style: .continuous).strokeBorder(VQ.Colors.hairline, lineWidth: 1))
        .padding(.horizontal, VQ.Spacing.page)
        .padding(.vertical, VoiceIQUI.Spacing.s)
    }

    private func labeledField(_ label: String, example: String, text: Binding<String>, field: AddField) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(VoiceIQUI.Colors.onSurfaceVariant)
            TextField(example, text: text)
                .textFieldStyle(.plain)
                .font(VoiceIQUI.TypeScale.body(grad: grad))
                .focused($focusedField, equals: field)
                .onSubmit(add)
        }
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
            VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xl) {
                section("Your words", filtered.filter { $0.source == .manual })
                section("Learned from your corrections", filtered.filter { $0.source == .auto })
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, VQ.Spacing.page)
            .padding(.vertical, VoiceIQUI.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [DictionaryEntry]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionCaption(text: "\(title) · \(items.count)")
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { entry in
                        entryRow(entry)
                        Rectangle().fill(VQ.Colors.hairline).frame(height: 1)
                    }
                }
            }
        }
    }

    /// One word on a hairline row: star, the spelling, what it is heard as.
    private func entryRow(_ entry: DictionaryEntry) -> some View {
        HStack(alignment: .center, spacing: VoiceIQUI.Spacing.s) {
            Button {
                store.toggleStar(id: entry.id)
                reload()
            } label: {
                Image(systemName: entry.starred ? "star.fill" : "star")
                    .foregroundStyle(entry.starred ? VQ.Colors.accent : VQ.Colors.faint)
            }
            .buttonStyle(.plain)
            .help("Starred words are prioritized")

            HStack(spacing: VoiceIQUI.Spacing.xs) {
                Text(entry.term)
                    .font(VoiceIQUI.TypeScale.bodyLarge(grad: grad))
                    .foregroundStyle(VQ.Colors.ink)
                    .lineLimit(1)
                if let subtitle = subtitle(entry) {
                    Text(subtitle)
                        .font(VoiceIQUI.TypeScale.body(grad: grad))
                        .foregroundStyle(VQ.Colors.muted)
                        .lineLimit(1)
                }
            }
            .help([entry.term, subtitle(entry)].compactMap { $0 }.joined(separator: "\n"))
            Spacer(minLength: 0)
            Button {
                store.remove(id: entry.id)
                reload()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(VQ.Colors.muted)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .frame(minHeight: 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subtitle(_ entry: DictionaryEntry) -> String? {
        if let misspelling = entry.misspelling, !misspelling.isEmpty { return "heard as “\(misspelling)”" }
        if let learnedFrom = entry.learnedFrom, !learnedFrom.isEmpty { return "heard as “\(learnedFrom)”" }
        return nil
    }

    private var emptyState: some View {
        Text("No words yet. Add a name or a term above, and it's spelled right in every dictation.")
            .font(VoiceIQUI.TypeScale.body(grad: grad))
            .foregroundStyle(VQ.Colors.muted)
            .padding(.horizontal, VQ.Spacing.page)
            .padding(.top, VoiceIQUI.Spacing.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack {
            Text(feedback ?? "\(entries.count) \(entries.count == 1 ? "word" : "words")")
                .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(feedback == nil ? VQ.Colors.muted : VoiceIQUI.Colors.primary)
            Spacer()
            Button("Import CSV…", action: importCSV)
                .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(VQ.Colors.accent)
            Button("Export CSV…", action: exportCSV)
                .font(VoiceIQUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(entries.isEmpty ? VQ.Colors.faint : VQ.Colors.accent)
                .disabled(entries.isEmpty)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, VQ.Spacing.page)
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
