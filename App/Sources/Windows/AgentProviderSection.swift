import VoiceIQCore
import SwiftUI

/// Settings → Advanced: the model host Agent mode uses instead of the
/// selected provider. Everything but the key persists as it is
/// typed; the key follows the same save-and-validate flow as the other keys.
struct AgentProviderSection: View {
    private let settings = SettingsStore()
    @State private var override = SettingsStore().agentProviderOverride
    @State private var apiKey = ""
    @State private var keyStatus: AdvancedPane.KeyStatus = KeychainStore.loadAgentProviderKey() == nil ? .missing : .stored
    @State private var newModelID = ""
    @State private var newModelName = ""
    @State private var validationNote: String?

    private var hasStoredKey: Bool { keyStatus == .stored || keyStatus == .valid || keyStatus == .savedOffline }

    private var baseURLLooksBroken: Bool {
        let trimmed = override.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && SettingsStore.usableEndpointURL(trimmed) == nil
    }

    private var canValidate: Bool {
        override.usableBaseURL != nil && (hasStoredKey || !apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        Section {
            Toggle("Custom provider", isOn: $override.enabled)
            if override.enabled {
                endpointRows
                formatRow
                PairRows(title: "Headers", rows: $override.headers, namePrompt: "x-custom-header")
                PairRows(title: "Query parameters", rows: $override.queryParameters, namePrompt: "key")
                modelRows
                actionRow
            }
        } header: {
            Text("Agent mode provider")
        } footer: {
            Text("Only Agent mode uses this host. Leave it off and Agent mode runs on the provider selected above. Works with CLIProxyAPI or any host that speaks one of the four formats; enter the URL before the API path. The key is stored in your Mac's Keychain.")
        }
        .onChange(of: override) { _, value in settings.setAgentProviderOverride(value) }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            if note.object as? String == KeychainStore.Secret.agentProvider.settingKey, keyStatus == .missing || keyStatus == .stored {
                keyStatus = KeychainStore.loadAgentProviderKey() == nil ? .missing : .stored
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private var endpointRows: some View {
        LabeledContent("Base URL") {
            TextField("", text: $override.baseURL, prompt: Text("https://example.com"))
                .labelsHidden()
                .font(VoiceIQUI.TypeScale.code)
                .multilineTextAlignment(.trailing)
        }
        if baseURLLooksBroken {
            Text("Not a valid http(s) URL.")
                .font(VoiceIQUI.TypeScale.labelSmall())
                .foregroundStyle(VoiceIQUI.Colors.error)
        }
        HStack {
            LabeledContent("API key") {
                SecureField("", text: $apiKey, prompt: Text(hasStoredKey ? "••••••••  (stored in Keychain)" : "Paste your key"))
                    .labelsHidden()
                    .font(VoiceIQUI.TypeScale.code)
                    .multilineTextAlignment(.trailing)
            }
            keyStatusBadge
        }
        if keyStatus == .invalid {
            Text("The host refused that key\(hasStoredKey ? " — your saved key is unchanged" : "").")
                .font(VoiceIQUI.TypeScale.labelSmall())
                .foregroundStyle(VoiceIQUI.Colors.error)
        }
        if keyStatus == .saveFailed {
            Text("The key validated but couldn't be saved to your Keychain — try again.")
                .font(VoiceIQUI.TypeScale.labelSmall())
                .foregroundStyle(VoiceIQUI.Colors.error)
        }
        if let validationNote {
            Text(validationNote)
                .font(VoiceIQUI.TypeScale.labelSmall())
                .foregroundStyle(keyStatus == .valid ? .secondary : VoiceIQUI.Colors.error)
        }
    }

    private var formatRow: some View {
        Picker("API format", selection: $override.format) {
            ForEach(AgentAPIFormat.allCases) { format in
                Text(format.displayName).tag(format)
            }
        }
        .pickerStyle(.radioGroup)
    }

    @ViewBuilder
    private var modelRows: some View {
        if override.models.isEmpty {
            LabeledContent("Model") {
                Text("Add a model ID below")
                    .foregroundStyle(.secondary)
            }
        } else {
            Picker("Model", selection: $override.selectedModelID) {
                ForEach(override.models) { model in
                    Text(model.label).tag(Optional(model.id))
                }
            }
            ForEach(override.models) { model in
                HStack(spacing: VoiceIQUI.Spacing.xs) {
                    Text(model.id)
                        .font(VoiceIQUI.TypeScale.code)
                    if model.displayName?.isEmpty == false {
                        Text(model.label)
                            .font(VoiceIQUI.TypeScale.labelSmall())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        removeModel(model.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(model.id)")
                }
            }
        }
        LabeledContent("New model ID") {
            TextField("", text: $newModelID, prompt: Text("gpt-6-luna"))
                .labelsHidden()
                .font(VoiceIQUI.TypeScale.code)
                .multilineTextAlignment(.trailing)
                .onSubmit { addModel() }
        }
        LabeledContent("Display name") {
            TextField("", text: $newModelName, prompt: Text("Optional"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .onSubmit { addModel() }
        }
        HStack {
            Spacer()
            Button("Add Model") { addModel() }
                .disabled(newModelID.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var actionRow: some View {
        HStack {
            Button("Save & Validate") { saveAndValidate() }
                .disabled(!canValidate)
            if hasStoredKey {
                Button("Remove Key…", role: .destructive) { removeKey() }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var keyStatusBadge: some View {
        switch keyStatus {
        case .missing:
            Image(systemName: "key.slash").foregroundStyle(.secondary)
        case .stored, .savedOffline:
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .validating:
            ProgressView().controlSize(.small)
        case .valid:
            Image(systemName: "checkmark.circle").foregroundStyle(VoiceIQUI.Colors.success)
        case .invalid, .saveFailed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(VoiceIQUI.Colors.error)
        }
    }

    // MARK: - Actions

    private func addModel() {
        let id = newModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !override.models.contains(where: { $0.id == id }) else { return }
        let name = newModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        override.models.append(AgentModel(id: id, displayName: name.isEmpty ? nil : name))
        if override.selectedModelID == nil { override.selectedModelID = id }
        newModelID = ""
        newModelName = ""
    }

    private func removeModel(_ id: String) {
        override.models.removeAll { $0.id == id }
        if override.selectedModelID == id { override.selectedModelID = override.models.first?.id }
    }

    /// Saves the typed key, then asks the host for its model list. A host
    /// that answers at all proves the URL, format and key together; one
    /// that cannot be reached keeps the key and defers the check.
    private func saveAndValidate() {
        guard let base = override.usableBaseURL else { return }
        let typed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? KeychainStore.loadAgentProviderKey() : typed
        keyStatus = .validating
        validationNote = nil
        let endpoint = AgentEndpoint(
            baseURL: base, apiKey: key, format: override.format,
            headers: Dictionary(AgentProviderOverride.pairs(override.headers).map { ($0.name, $0.value) }, uniquingKeysWith: { $1 }),
            queryParameters: Dictionary(AgentProviderOverride.pairs(override.queryParameters).map { ($0.name, $0.value) }, uniquingKeysWith: { $1 }),
            modelID: override.selectedModelID ?? "", label: "Custom", isCustom: true
        )
        let configured = override.models.map(\.id)
        Task {
            do {
                let listed = try await endpoint.listModels()
                guard typed.isEmpty || KeychainStore.saveAgentProviderKey(typed) else {
                    keyStatus = .saveFailed
                    return
                }
                apiKey = ""
                keyStatus = .valid
                let unknown = configured.filter { !listed.contains($0) }
                if listed.isEmpty {
                    validationNote = "The host answered but listed no models."
                } else if unknown.isEmpty {
                    validationNote = "The host lists \(listed.count) models\(configured.isEmpty ? "" : ", including yours")."
                } else {
                    validationNote = "The host does not list: \(unknown.joined(separator: ", ")). Check the IDs."
                }
            } catch let error as AgentTransportError {
                switch error {
                case .http(401, _), .http(403, _):
                    keyStatus = .invalid
                case .http, .malformed:
                    keyStatus = typed.isEmpty || KeychainStore.saveAgentProviderKey(typed) ? .stored : .saveFailed
                    apiKey = ""
                    validationNote = error.userMessage
                case .network, .noEndpoint:
                    keyStatus = typed.isEmpty || KeychainStore.saveAgentProviderKey(typed) ? .savedOffline : .saveFailed
                    apiKey = ""
                    validationNote = "Couldn't reach the host — key saved; it'll be checked on your first command."
                }
            } catch {
                keyStatus = typed.isEmpty || KeychainStore.saveAgentProviderKey(typed) ? .savedOffline : .saveFailed
                apiKey = ""
                validationNote = "Couldn't reach the host — key saved; it'll be checked on your first command."
            }
        }
    }

    private func removeKey() {
        KeychainStore.deleteAgentProviderKey(notify: true)
        apiKey = ""
        keyStatus = .missing
        validationNote = nil
    }
}

/// Editable name/value rows for headers or query parameters.
private struct PairRows: View {
    let title: String
    @Binding var rows: [AgentKeyValue]
    let namePrompt: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button("Add") { rows.append(AgentKeyValue()) }
        }
        ForEach($rows) { $row in
            HStack(spacing: VoiceIQUI.Spacing.xs) {
                TextField("Name", text: $row.name, prompt: Text(namePrompt))
                    .labelsHidden()
                    .font(VoiceIQUI.TypeScale.code)
                TextField("Value", text: $row.value, prompt: Text("value"))
                    .labelsHidden()
                    .font(VoiceIQUI.TypeScale.code)
                Button {
                    rows.removeAll { $0.id == row.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove \(title.lowercased()) row")
            }
        }
    }
}
