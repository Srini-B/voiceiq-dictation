import Combine
import SwiftUI

/// The Meetings views' folder state, shared by the Mac and iPhone so both
/// file, filter, name and delete folders the same way. The view calls
/// `reload` whenever it reloads its meetings.
@MainActor
public final class MeetingFolderModel: ObservableObject {
    public enum Edit: Identifiable, Equatable {
        /// Name a new folder, and file this meeting in it when there is one.
        case create(fileIn: MeetingID?)
        case rename(MeetingFolder)
        case delete(MeetingFolder)

        public var id: String {
            switch self {
            case .create(let meeting): "create-\(meeting?.uuid.uuidString ?? "")"
            case .rename(let folder): "rename-\(folder.id)"
            case .delete(let folder): "delete-\(folder.id)"
            }
        }
    }

    public let store: MeetingStore
    @Published public private(set) var folders: [MeetingFolder] = []
    /// The live folders each meeting is in, as of the last `reload`.
    @Published public private(set) var filed: [MeetingID: [UUID]] = [:]
    /// Each meeting's `folder-ids.json` as read, which may name folders that
    /// have not synced here yet; `filed` is rebuilt from it when they do.
    private var stored: [MeetingID: [UUID]] = [:]
    /// Nil shows every meeting.
    @Published public var filter: UUID?
    @Published public var edit: Edit?
    /// The name being typed for `edit`.
    @Published public var draft = ""
    private var observer: AnyCancellable?

    public init(store: MeetingStore = MeetingStore()) {
        self.store = store
        folders = store.folders()
        observer = NotificationCenter.default.publisher(for: .gtMeetingFoldersDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.reloadFolders() } }
    }

    public func reload(_ meetings: [MeetingMeta]) {
        stored = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, store.storedFolderIDs(of: $0.id)) })
        reloadFolders()
    }

    private func reloadFolders() {
        let snapshot = store.foldersSnapshot()
        folders = snapshot.folders
        // Combined with another folder, or deleted, here or on another device.
        if let filter { self.filter = snapshot.resolve([filter]).first }
        filed = stored.mapValues(snapshot.resolve)
    }

    /// The meetings the filter shows, in their order.
    public func shown(_ meetings: [MeetingMeta]) -> [MeetingMeta] {
        guard let filter else { return meetings }
        return meetings.filter { filed[$0.id]?.contains(filter) ?? false }
    }

    public var filterFolder: MeetingFolder? { folders.first { $0.id == filter } }

    /// The meeting's folders by name.
    public func names(of meeting: MeetingID) -> [String] {
        let ids = Set(filed[meeting] ?? [])
        return folders.filter { ids.contains($0.id) }.map(\.name)
    }

    public func isFiled(_ meeting: MeetingID, in folder: UUID) -> Bool { filed[meeting]?.contains(folder) ?? false }

    public func file(_ meeting: MeetingID, in folder: UUID, _ member: Bool) {
        do {
            try store.setMeeting(meeting, inFolder: folder, member)
            stored[meeting] = store.storedFolderIDs(of: meeting)
            filed[meeting] = store.folderIDs(of: meeting)
        } catch {
            Log.meeting.error("meeting folders: could not file \(meeting.uuid.uuidString, privacy: .public): \(error)")
        }
    }

    public func begin(_ edit: Edit) {
        if case .rename(let folder) = edit { draft = folder.name } else { draft = "" }
        self.edit = edit
    }

    public var draftIsValid: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Saves the typed name: a new folder is shown, and the meeting it was
    /// made from is filed in it.
    public func commitName() {
        defer { edit = nil }
        do {
            switch edit {
            case .create(let meeting)?:
                try createFolder(named: draft, fileIn: meeting)
            case .rename(let folder)?:
                try store.renameFolder(folder.id, to: draft)
            case .delete?, nil:
                break
            }
        } catch {
            Log.meeting.error("meeting folders: could not save a name: \(error)")
        }
        reloadFolders()
    }

    /// A new folder, shown in the list, or with this meeting filed in it.
    public func createFolder(named name: String, fileIn meeting: MeetingID?) throws {
        let folder = try store.createFolder(named: name)
        if let meeting { file(meeting, in: folder.id, true) } else { filter = folder.id }
        reloadFolders()
    }

    public func commitDelete() {
        defer { edit = nil }
        guard case .delete(let folder)? = edit else { return }
        try? store.deleteFolder(folder.id)
        reloadFolders()
    }
}

/// Menu items that file one meeting in folders: a checkmark per folder, then New Folder.
public struct MeetingFolderToggles: View {
    @ObservedObject var model: MeetingFolderModel
    let meeting: MeetingID

    public init(model: MeetingFolderModel, meeting: MeetingID) { self.model = model; self.meeting = meeting }

    public var body: some View {
        ForEach(model.folders) { folder in
            Toggle(folder.name, isOn: Binding(get: { model.isFiled(meeting, in: folder.id) },
                                              set: { model.file(meeting, in: folder.id, $0) }))
        }
        if !model.folders.isEmpty { Divider() }
        Button("New Folder…", systemImage: "folder.badge.plus") { model.begin(.create(fileIn: meeting)) }
    }
}

/// The folders as a list to tick, for a sheet: what a swipe on an iPhone
/// row opens, where a menu cannot.
public struct MeetingFolderPicker: View {
    @ObservedObject var model: MeetingFolderModel
    let meeting: MeetingID
    let done: () -> Void
    @State private var naming = false
    @State private var newName = ""

    public init(model: MeetingFolderModel, meeting: MeetingID, done: @escaping () -> Void) {
        self.model = model; self.meeting = meeting; self.done = done
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(model.folders) { folder in
                    Button {
                        model.file(meeting, in: folder.id, !model.isFiled(meeting, in: folder.id))
                    } label: {
                        HStack {
                            Label(folder.name, systemImage: "folder")
                            Spacer()
                            if model.isFiled(meeting, in: folder.id) { Image(systemName: "checkmark").fontWeight(.semibold) }
                        }
                    }
                }
                Button("New Folder…", systemImage: "folder.badge.plus") { newName = ""; naming = true }
            }
            .navigationTitle("Folders")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
            // Its own dialog: the list's `meetingFolderEditing` one sits under this sheet.
            .alert("New Folder", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { try? model.createFolder(named: newName, fileIn: meeting) }
            }
        }
    }
}

/// Menu items that choose which meetings the list shows, and manage the
/// folder shown.
public struct MeetingFolderFilterItems: View {
    @ObservedObject var model: MeetingFolderModel
    let allTitle: String

    public init(model: MeetingFolderModel, allTitle: String) { self.model = model; self.allTitle = allTitle }

    public var body: some View {
        Picker("Show", selection: $model.filter) {
            Label(allTitle, systemImage: "tray.full").tag(UUID?.none)
            ForEach(model.folders) { folder in
                Label(folder.name, systemImage: "folder").tag(UUID?.some(folder.id))
            }
        }
        .pickerStyle(.inline)
        Divider()
        Button("New Folder…", systemImage: "folder.badge.plus") { model.begin(.create(fileIn: nil)) }
        if let folder = model.filterFolder {
            Button("Rename “\(folder.name)”…", systemImage: "pencil") { model.begin(.rename(folder)) }
            Button("Delete “\(folder.name)”…", systemImage: "trash", role: .destructive) { model.begin(.delete(folder)) }
        }
    }
}

public extension View {
    /// The dialogs `MeetingFolderModel.edit` asks for: a name for a new or
    /// renamed folder, and the confirmation before a folder is deleted.
    func meetingFolderEditing(_ model: MeetingFolderModel, noun: String) -> some View {
        modifier(MeetingFolderEditing(model: model, noun: noun))
    }
}

private struct MeetingFolderEditing: ViewModifier {
    @ObservedObject var model: MeetingFolderModel
    /// "meetings" on the Mac, "notes" on the iPhone.
    let noun: String

    private var naming: Binding<Bool> {
        Binding(get: { if case .delete = model.edit { return false }; return model.edit != nil },
                set: { if !$0 { model.edit = nil } })
    }

    private var deleting: Binding<Bool> {
        Binding(get: { if case .delete = model.edit { return true }; return false },
                set: { if !$0 { model.edit = nil } })
    }

    private var deletedName: String { if case .delete(let folder)? = model.edit { return folder.name }; return "" }
    private var renaming: Bool { if case .rename? = model.edit { return true }; return false }

    func body(content: Content) -> some View {
        content
            .alert(renaming ? "Rename Folder" : "New Folder", isPresented: naming) {
                TextField("Name", text: $model.draft)
                Button("Cancel", role: .cancel) { model.edit = nil }
                Button(renaming ? "Rename" : "Create") { model.commitName() }.disabled(!model.draftIsValid)
            }
            .confirmationDialog("Delete the folder “\(deletedName)”?", isPresented: deleting, titleVisibility: .visible) {
                Button("Delete Folder", role: .destructive) { model.commitDelete() }
            } message: {
                Text("The \(noun) in it are not deleted.")
            }
    }
}
