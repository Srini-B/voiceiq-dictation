import SwiftUI
import UniformTypeIdentifiers
import VoiceIQCore

/// Settings › Dictionary, as on the Mac: search, add with "Heard as", the
/// user's words and the auto-learned ones (learned on the Mac, synced through
/// iCloud), stars, and CSV import and export.
struct DictionaryView: View {
    private let store = DictionaryStore()
    @State private var entries: [DictionaryEntry] = []
    @State private var newTerm = ""
    @State private var misspelling = ""
    @State private var search = ""
    @State private var feedback: String?
    @State private var importing = false
    @State private var exporting = false

    var body: some View {
        Form {
            Section {
                // Labels beside the fields stay once they are filled in, so the
                // two can't be typed into each other's field.
                LabeledContent("Write it as") {
                    TextField("Write it as", text: $newTerm, prompt: Text("e.g. Kubernetes"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                LabeledContent("Heard as") {
                    TextField("Heard as", text: $misspelling, prompt: Text("Optional, e.g. cooper netties"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                HStack {
                    if let feedback {
                        Text(feedback).font(Theme.Fonts.footnote()).foregroundStyle(Theme.Colors.muted)
                    }
                    Spacer()
                    Button("Add", action: add)
                        .buttonStyle(.compactPrimary)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !manual.isEmpty {
                Section {
                    ForEach(manual) { row($0) }.onDelete { remove(manual, at: $0) }
                } header: { SettingsSectionHeader("Dictionary") }
            }
            if !auto.isEmpty {
                Section {
                    ForEach(auto) { row($0) }.onDelete { remove(auto, at: $0) }
                } header: { SettingsSectionHeader("Auto-learned") }
            }
            Section {
                Text("\(entries.count) \(entries.count == 1 ? "word" : "words")")
                    .font(Theme.Fonts.footnote()).foregroundStyle(Theme.Colors.muted)
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your dictionary")
        .settingsPage(title: "Dictionary", keyboard: true)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Import CSV…", systemImage: "square.and.arrow.down") { importing = true }
                    Button("Export CSV…", systemImage: "square.and.arrow.up") { exporting = true }
                        .disabled(entries.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Import or export")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            importCSV(result)
        }
        .fileExporter(isPresented: $exporting, document: CSVDocument(text: store.exportCSV()),
                      contentType: .commaSeparatedText, defaultFilename: "voiceiq-dictionary") { result in
            if case .success = result { show("Exported \(entries.count) \(entries.count == 1 ? "word" : "words")") }
        }
        .onAppear(perform: reload)
        // Words added from the keyboard or synced from the Mac arrive while
        // the page is open.
        .onReceive(NotificationCenter.default.publisher(for: .gtDictionaryDidChange).receive(on: RunLoop.main)) { _ in reload() }
    }

    private var filtered: [DictionaryEntry] {
        let sorted = entries.sorted {
            if $0.starred != $1.starred { return $0.starred }
            return $0.createdAt > $1.createdAt
        }
        guard !search.isEmpty else { return sorted }
        return sorted.filter {
            $0.term.localizedCaseInsensitiveContains(search)
                || ($0.misspelling?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    private var manual: [DictionaryEntry] { filtered.filter { $0.source == .manual } }
    private var auto: [DictionaryEntry] { filtered.filter { $0.source == .auto } }

    private func row(_ entry: DictionaryEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(entry.term).font(Theme.Fonts.body()).foregroundStyle(Theme.Colors.ink)
                if let wrong = entry.misspelling, !wrong.isEmpty {
                    Text("“\(wrong)” → \(entry.term)").font(Theme.Fonts.caption()).foregroundStyle(Theme.Colors.muted)
                } else if let heard = entry.learnedFrom, !heard.isEmpty {
                    Text("Heard as “\(heard)”").font(Theme.Fonts.caption()).foregroundStyle(Theme.Colors.muted)
                }
            }
            Spacer()
            Button {
                store.toggleStar(id: entry.id)
                reload()
            } label: {
                Image(systemName: entry.starred ? "star.fill" : "star")
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(entry.starred ? "Remove favorite" : "Add favorite")
        }
    }

    private func add() {
        let wrong = misspelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.add(term: newTerm, misspelling: wrong.isEmpty ? nil : wrong) else {
            let trimmed = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            show(trimmed.count > 60 ? "Keep terms under 60 characters" : "Already in your dictionary")
            return
        }
        newTerm = ""
        misspelling = ""
        reload()
    }

    private func remove(_ list: [DictionaryEntry], at offsets: IndexSet) {
        for index in offsets { store.remove(id: list[index].id) }
        reload()
    }

    private func importCSV(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let csv = try? String(contentsOf: url, encoding: .utf8) else {
            show("Couldn't read that file")
            return
        }
        let count = store.importCSV(csv)
        reload()
        show(count == 0 ? "Nothing new to import" : "Imported \(count) \(count == 1 ? "word" : "words")")
    }

    private func reload() {
        entries = store.entries()
    }

    private func show(_ message: String) {
        feedback = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if feedback == message { feedback = nil }
        }
    }
}

/// The CSV for `fileExporter`.
private struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
