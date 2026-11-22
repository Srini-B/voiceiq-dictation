import AppKit
import SwiftUI
import VoiceIQCore

/// Settings › Advanced › Coding agents: the switch for `AgentServer` and the
/// setup each agent needs, with the access key already filled in.
struct AgentAccessSection: View {
    private let settings = SettingsStore()
    @State private var enabled = SettingsStore().agentAccessEnabled
    @State private var state = AgentServer.shared.state
    @State private var copied: String?
    @State private var confirmingNewKey = false
    @State private var statuses: [AgentClient: AgentClient.Status] = [:]

    var body: some View {
        Section {
            Toggle("Let coding agents read History and meetings", isOn: $enabled)
                .onChange(of: enabled) { _, on in settings.setAgentAccessEnabled(on) }
            LabeledContent("Status") {
                Text(status).foregroundStyle(isFailed ? VoiceIQUI.Colors.error : .secondary)
            }
            if enabled {
                ForEach(AgentClient.allCases) { client in
                    LabeledContent(client.name) {
                        HStack {
                            Text(Self.describe(statuses[client])).foregroundStyle(.secondary)
                            switch statuses[client] {
                            case .notSetUp: Button("Set Up") { change(client, add: true) }
                            case .needsUpdate: Button("Update") { change(client, add: true) }
                            case .setUp: Button("Remove") { change(client, add: false) }
                            default: EmptyView()
                            }
                        }
                    }
                }
                HStack {
                    copyButton("Copy for Other Tools", "MCP JSON") { key in
                        """
                        {
                          "mcpServers": {
                            "voiceiq": {
                              "type": "http",
                              "url": "\(AgentAPI.mcpURL)",
                              "headers": { "Authorization": "Bearer \(key)" }
                            }
                          }
                        }
                        """
                    }
                    copyButton("Copy Key", "access key") { $0 }
                    Spacer()
                    Button("New Key…") { confirmingNewKey = true }
                        .confirmationDialog("Make a new access key? Claude Code, Codex and Amp get it here; other tools stop working until you set them up again.",
                                            isPresented: $confirmingNewKey) {
                            Button("Make New Key", role: .destructive) { AgentServer.resetAccessKey(); copied = nil }
                        }
                }
                Text(copied.map { "Copied the \($0)." } ?? "VoiceiQ adds itself to Claude Code, Codex and Amp when they're on this Mac, and keeps their key current. For Cursor, Gemini CLI and others, merge the copied JSON into their MCP settings.")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(.secondary)
                Link("Tools, routes and security", destination: URL(string: "https://github.com/Srini-B/voiceiq-dictation/blob/main/docs/AGENT_ACCESS.md")!)
                    .font(VoiceIQUI.TypeScale.labelSmall())
            }
        } header: {
            Text("Coding agents")
        } footer: {
            Text("Claude Code, Codex, Amp and other tools on this Mac can list and search your dictations and meetings, including the ones synced from your iPhone, and read a meeting's notes, transcript and questions. They can't change or delete anything. VoiceiQ answers only on 127.0.0.1, only while this is on, and only to requests carrying the access key, which stays in your Keychain and in the agents you give it to. Anything an agent reads goes to that agent's AI provider.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .gtAgentServerStateDidChange)) { _ in
            state = AgentServer.shared.state
            refreshStatuses()
        }
        .onAppear {
            state = AgentServer.shared.state
            refreshStatuses()
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private var status: String {
        switch state {
        case .off: "Off"
        case .starting: "Starting…"
        case .listening: "On at \(AgentAPI.mcpURL), this Mac only"
        case .failed(let reason): reason
        }
    }

    private static func describe(_ status: AgentClient.Status?) -> String {
        switch status {
        case nil: ""
        case .notInstalled: "Not found on this Mac"
        case .notSetUp: "Not set up"
        case .setUp: "Set up"
        case .needsUpdate: "Has an old key"
        case .otherServer: "Has another server named voiceiq"
        case .unreadable: "Can't edit its settings file safely; copy the JSON instead"
        }
    }

    /// Reads each agent's config off the main thread: `~/.claude.json` can be large.
    private func refreshStatuses() {
        Task {
            statuses = await Task.detached(priority: .userInitiated) {
                let key = AgentServer.accessKey() ?? ""
                let home = FileManager.default.homeDirectoryForCurrentUser
                return Dictionary(uniqueKeysWithValues: AgentClient.allCases.map { ($0, $0.status(key: key, home: home)) })
            }.value
        }
    }

    /// Set Up and Update add the agent back to the ones VoiceiQ keeps current; Remove takes it out of them.
    private func change(_ client: AgentClient, add: Bool) {
        var removed = settings.agentAccessRemovedClients
        if add { removed.remove(client.rawValue) } else { removed.insert(client.rawValue) }
        settings.setAgentAccessRemovedClients(removed)
        AgentServer.shared.syncClientsNow()
    }

    private func copyButton(_ title: String, _ what: String, _ text: @escaping (String) -> String) -> some View {
        Button(title) {
            guard let key = AgentServer.accessKey() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(key), forType: .string)
            copied = what
        }
        .help("Copy the \(what)")
    }
}
