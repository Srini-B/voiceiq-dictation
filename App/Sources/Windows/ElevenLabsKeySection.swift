import VoiceIQCore
import SwiftUI

struct ElevenLabsKeySection: View {
    @State private var apiKey = ""
    @State private var keyStatus: AdvancedPane.KeyStatus = KeychainStore.loadElevenLabsKey() == nil ? .missing : .stored

    private var hasStoredKey: Bool {
        keyStatus == .stored || keyStatus == .valid || keyStatus == .savedOffline
    }

    var body: some View {
        Section {
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
                Text(KeychainStore.loadElevenLabsKey() != nil
                     ? "That key didn't work. Your saved key is unchanged."
                     : "ElevenLabs rejected that key.")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(VoiceIQUI.Colors.error)
            }
            if keyStatus == .saveFailed {
                Text("The key validated but couldn't be saved to your Keychain. Try again.")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(VoiceIQUI.Colors.error)
            }
            if keyStatus == .savedOffline {
                Text("You look offline. The key was saved and will be checked on your first dictation.")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Save & Validate") { saveAndValidate() }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                if hasStoredKey {
                    Button("Remove Key…", role: .destructive) {
                        KeychainStore.deleteElevenLabsKey(notify: true)
                        apiKey = ""
                        keyStatus = .missing
                    }
                }
                Spacer()
                Link("Get a key at ElevenLabs", destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!)
                    .font(VoiceIQUI.TypeScale.labelSmall())
            }
        } header: {
            Text("ElevenLabs API key")
        } footer: {
            Text("Stored in your Mac's Keychain and only ever sent to ElevenLabs. Unlocks ElevenLabs Scribe as a transcription source.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            if note.object as? String == "elevenLabsKey", keyStatus == .missing || keyStatus == .stored {
                keyStatus = KeychainStore.loadElevenLabsKey() == nil ? .missing : .stored
            }
        }
    }

    @ViewBuilder
    private var keyStatusBadge: some View {
        switch keyStatus {
        case .missing: Image(systemName: "key.slash").foregroundStyle(.secondary)
        case .stored, .savedOffline: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .validating: ProgressView().controlSize(.small)
        case .valid: Image(systemName: "checkmark.circle").foregroundStyle(VoiceIQUI.Colors.success)
        case .invalid, .saveFailed: Image(systemName: "xmark.circle.fill").foregroundStyle(VoiceIQUI.Colors.error)
        }
    }

    private func saveAndValidate() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyStatus = .validating
        Task {
            let client = GeminiClient(apiKey: { nil }, elevenLabsKey: { key })
            let check = await client.validateElevenLabsKey()
            switch check {
            case .valid, .unreachable:
                if KeychainStore.saveElevenLabsKey(key) {
                    apiKey = ""
                    keyStatus = check == .valid ? .valid : .savedOffline
                } else {
                    keyStatus = .saveFailed
                }
            case .rejected:
                keyStatus = .invalid
            }
        }
    }
}
