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

    var body: some View {
        Section {
            Toggle("Let coding agents read History and meetings", isOn: $enabled)
                .onChange(of: enabled) { _, on in settings.setAgentAccessEnabled(on) }
            LabeledContent("Status") {
                Text(status).foregroundStyle(isFailed ? VoiceIQUI.Colors.error : .secondary)
            }
            if enabled {
                HStack {
                    copyButton("Claude Code", "Claude Code command") { key in
                        "claude mcp add --transport http --scope user voiceiq \(AgentAPI.mcpURL) --header \"Authorization: Bearer \(key)\""
                    }
                    copyButton("Codex", "Codex config") { key in
                        """
                        [mcp_servers.voiceiq]
                        url = "\(AgentAPI.mcpURL)"
                        http_headers = { Authorization = "Bearer \(key)" }

                        """
                    }
                    copyButton("Other tools", "MCP JSON") { key in
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
                    copyButton("Key", "access key") { $0 }
                    Spacer()
                    Button("New Key…") { confirmingNewKey = true }
                        .confirmationDialog("Make a new access key? Agents set up with the current key stop working until you set them up again.",
                                            isPresented: $confirmingNewKey) {
                            Button("Make New Key", role: .destructive) { AgentServer.resetAccessKey(); copied = nil }
                        }
                }
                Text(copied.map { "Copied the \($0)." } ?? "Claude Code: paste the command into Terminal. Codex: paste the config into ~/.codex/config.toml. Cursor, Gemini CLI and others: merge the JSON into their MCP settings.")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(.secondary)
                Link("Tools, routes and security", destination: URL(string: "https://github.com/Srini-B/voiceiq-dictation/blob/main/docs/AGENT_ACCESS.md")!)
                    .font(VoiceIQUI.TypeScale.labelSmall())
            }
        } header: {
            Text("Coding agents")
        } footer: {
            Text("Claude Code, Codex and other tools on this Mac can list and search your dictations and meetings, including the ones synced from your iPhone, and read a meeting's notes, transcript and questions. They can't change or delete anything. VoiceiQ answers only on 127.0.0.1, only while this is on, and only to requests carrying the access key, which stays in your Keychain and in the agents you give it to. Anything an agent reads goes to that agent's AI provider.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .gtAgentServerStateDidChange)) { _ in
            state = AgentServer.shared.state
        }
        .onAppear { state = AgentServer.shared.state }
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
