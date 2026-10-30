import Foundation

public enum DictionarySource: String, Codable, Sendable {
    case manual
    case auto
}

/// The personal dictionary: terms (spelling hints fed to the cleanup prompt) and
/// explicit wrong→right rules (enforced deterministically post-model).
/// UserDefaults-backed — entries are small and this keeps v1 dependency-free.
/// `DictionarySync` keeps it the same on every device on the iCloud account.
public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The correct term ("Kubernetes", "Ammaar", "gRPC"). 1–60 chars.
    public var term: String
    /// Optional misspelling the model tends to produce ("cooper netties").
    public var misspelling: String?
    /// For auto-learned words: the transcript wording the user replaced with
    /// `term`. Informational only; never a replacement rule.
    public var learnedFrom: String?
    public var starred: Bool
    public var createdAt: Date
    public var source: DictionarySource
    /// Last change on any device. Sync keeps the newer copy of an entry.
    public var updatedAt: Date

    public init(
        term: String,
        misspelling: String? = nil,
        learnedFrom: String? = nil,
        starred: Bool = false,
        source: DictionarySource = .manual
    ) {
        self.id = UUID()
        self.term = term
        self.misspelling = misspelling
        self.learnedFrom = learnedFrom
        self.starred = starred
        self.createdAt = Date()
        self.source = source
        self.updatedAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, term, misspelling, learnedFrom, starred, createdAt, source, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        term = try container.decode(String.self, forKey: .term)
        misspelling = try container.decodeIfPresent(String.self, forKey: .misspelling)
        learnedFrom = try container.decodeIfPresent(String.self, forKey: .learnedFrom)
        starred = try container.decode(Bool.self, forKey: .starred)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        source = try container.decodeIfPresent(DictionarySource.self, forKey: .source) ?? .manual
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        // Auto-learned entries used to be stored as wrong→right rules. Demote
        // them to plain words so an old edit cannot rewrite unrelated text.
        if source == .auto, let rule = misspelling {
            learnedFrom = learnedFrom ?? rule
            misspelling = nil
        }
    }

    /// Equal apart from `updatedAt`: whether an edit changed anything.
    func sameContent(as other: DictionaryEntry) -> Bool {
        var copy = other
        copy.updatedAt = updatedAt
        return copy == self
    }
}

public struct DictionaryStore: Sendable {
    private static let key = "dictionaryEntries"
    private static let tombstonesKey = "dictionaryTombstones"
    private static let defaults = UserDefaults.standard

    public init() {}

    public func entries() -> [DictionaryEntry] {
        guard let data = Self.defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder().decode([DictionaryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    /// Saves an edit made on this device. Changed entries get a new
    /// `updatedAt` and removed ones a tombstone, so sync can tell the edit
    /// from an older copy on another device.
    public func save(_ entries: [DictionaryEntry]) {
        let now = Date()
        let previous = Dictionary(self.entries().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var stamped = entries
        for index in stamped.indices {
            if let old = previous[stamped[index].id], old.sameContent(as: stamped[index]) { continue }
            stamped[index].updatedAt = now
        }
        var tombstones = self.tombstones()
        let kept = Set(stamped.map(\.id))
        for id in previous.keys where !kept.contains(id) {
            tombstones[id.uuidString] = now
        }
        write(DictionarySnapshot(entries: stamped, tombstones: tombstones), origin: "local")
    }

    // MARK: - Sync

    public func snapshot() -> DictionarySnapshot {
        DictionarySnapshot(entries: entries(), tombstones: tombstones())
    }

    /// Replaces the dictionary with a merged copy from sync, as is.
    public func apply(_ snapshot: DictionarySnapshot) {
        write(snapshot, origin: "sync")
    }

    private func tombstones() -> [String: Date] {
        guard let data = Self.defaults.data(forKey: Self.tombstonesKey),
              let tombstones = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return tombstones
    }

    private func write(_ snapshot: DictionarySnapshot, origin: String) {
        let encoder = JSONEncoder()
        guard let entries = try? encoder.encode(snapshot.entries),
              let tombstones = try? encoder.encode(snapshot.tombstones) else { return }
        Self.defaults.set(entries, forKey: Self.key)
        Self.defaults.set(tombstones, forKey: Self.tombstonesKey)
        NotificationCenter.default.post(name: .gtDictionaryDidChange, object: origin)
    }

    @discardableResult
    public func add(term: String, misspelling: String? = nil) -> Bool {
        add(term: term, misspelling: misspelling, source: .manual)
    }

    @discardableResult
    public func add(
        term: String,
        misspelling: String? = nil,
        learnedFrom: String? = nil,
        source: DictionarySource
    ) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(trimmed.count) else { return false }
        var current = entries()
        guard !current.contains(where: { $0.term.lowercased() == trimmed.lowercased() }) else { return false }
        current.append(DictionaryEntry(
            term: trimmed,
            misspelling: misspelling?.trimmingCharacters(in: .whitespacesAndNewlines),
            learnedFrom: learnedFrom?.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source
        ))
        save(current)
        return true
    }

    public func autoLearned() -> [DictionaryEntry] {
        entries().filter { $0.source == .auto }
    }

    public func remove(id: UUID) {
        save(entries().filter { $0.id != id })
    }

    /// Renames an entry in place. The id, origin and `learnedFrom` survive
    /// so sync treats it as an edit, not a removal plus an addition.
    public func update(id: UUID, term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(trimmed.count) else { return }
        var current = entries()
        guard let index = current.firstIndex(where: { $0.id == id }) else { return }
        current[index].term = trimmed
        save(current)
    }

    public func toggleStar(id: UUID) {
        var current = entries()
        if let index = current.firstIndex(where: { $0.id == id }) {
            current[index].starred.toggle()
            save(current)
        }
    }

    // MARK: - Pipeline inputs

    /// Vocabulary for the cleanup prompt: starred first, then words the user
    /// added over auto-learned ones (the keyboard can learn hundreds), then
    /// newest. Cap 100.
    public func vocabulary() -> [String] {
        let sorted = entries().sorted {
            if $0.starred != $1.starred { return $0.starred }
            if $0.source != $1.source { return $0.source == .manual }
            return $0.createdAt > $1.createdAt
        }
        return sorted.prefix(100).map(\.term)
    }

    /// Vocabulary as it goes over the wire — the SHARED sanitizer for both the
    /// cleanup prompt and the transcription request's `custom_vocabulary`.
    ///
    /// Dictionary entries are user/CSV data, so newlines are stripped and each
    /// term capped (audit L31: a crafted entry must not be able to smuggle its
    /// own instruction line into the prompt). Both consumers call this so they
    /// cannot drift apart, and a total-byte ceiling bounds the request whatever
    /// the per-term caps allow. Only CORRECT terms — never misspellings; biasing
    /// a recogniser toward "cooper netties" is actively harmful, and spellings()
    /// sits close enough to be wired up by accident.
    public func sanitizedVocabulary(maxBytes: Int = 2_048) -> [String] {
        var used = 0
        var out: [String] = []
        for term in vocabulary() {
            let clean = String(
                term.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .prefix(60)
            ).trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { continue }
            let cost = clean.utf8.count + 1
            guard used + cost <= maxBytes else { break } // truncate from the END: starred survive
            used += cost
            out.append(clean)
        }
        return out
    }

    /// Spelling hints for the prompt (top 10 with misspellings) — starred first,
    /// matching vocabulary(): "Starred words are prioritized" must be true for
    /// both prompt inputs, not just one.
    public func spellings() -> [(wrong: String, right: String)] {
        entries()
            .sorted {
                if $0.starred != $1.starred { return $0.starred }
                return $0.createdAt > $1.createdAt
            }
            .compactMap { entry in
                entry.misspelling.flatMap { $0.isEmpty ? nil : (wrong: $0, right: entry.term) }
            }
            .prefix(10)
            .map { $0 }
    }

    /// Deterministic rules for the ReplacementEngine (ALL entries with misspellings).
    public func replacementRules() -> [ReplacementEngine.Rule] {
        entries().compactMap { entry in
            entry.misspelling.flatMap { $0.isEmpty ? nil : ReplacementEngine.Rule(wrong: $0, right: entry.term) }
        }
    }

    // MARK: - CSV (data portability)

    public func exportCSV() -> String {
        var lines = ["term,misspelling"]
        for entry in entries() {
            let term = entry.term.replacingOccurrences(of: "\"", with: "\"\"")
            let misspelling = (entry.misspelling ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\"\(term)\",\"\(misspelling)\"")
        }
        return lines.joined(separator: "\n")
    }

    /// Quote-aware record splitter: CRLF endings and RFC-4180 quoted newlines
    /// both broke the naive \n split (dropped/mangled rows while reporting
    /// success — production pass 2).
    private func splitRecords(_ csv: String) -> [String] {
        var records: [String] = []
        var current = ""
        var inQuotes = false
        for char in csv {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if !inQuotes, char == "\n" || char == "\r" || char == "\r\n" {
                if !current.isEmpty { records.append(current) }
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { records.append(current) }
        return records
    }

    @discardableResult
    public func importCSV(_ csv: String) -> Int {
        var lines = splitRecords(csv)
        // Only drop the first line when its first CELL is exactly a header word —
        // hasPrefix("term") would eat a real first entry like "terminal" from a
        // headerless file (audit L30 + settings live-audit).
        if let first = lines.first {
            let firstCell = parseCSVLine(first).first?.lowercased() ?? ""
            if ["term", "word", "phrase"].contains(firstCell) {
                lines.removeFirst()
            }
        }
        // Batch: one load + one save. Per-row add() re-decodes the whole store
        // from UserDefaults every time — O(n²) and a visible hitch at the cap.
        var current = entries()
        var seen = Set(current.map { $0.term.lowercased() })
        var imported = 0
        for line in lines where imported < 1000 {
            let columns = parseCSVLine(line)
            guard let rawTerm = columns.first else { continue }
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...60).contains(term.count), !seen.contains(term.lowercased()) else { continue }
            let misspelling = columns.count > 1 && !columns[1].isEmpty ? columns[1] : nil
            current.append(DictionaryEntry(term: term, misspelling: misspelling))
            seen.insert(term.lowercased())
            imported += 1
        }
        if imported > 0 {
            save(current)
        }
        return imported
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var columns: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            switch (char, inQuotes) {
            case ("\"", true) where index + 1 < chars.count && chars[index + 1] == "\"":
                current.append("\"") // RFC 4180 escaped quote (audit L30)
                index += 1
            case ("\"", _):
                inQuotes.toggle()
            case (",", false):
                columns.append(current)
                current = ""
            default:
                current.append(char)
            }
            index += 1
        }
        columns.append(current)
        return columns.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
