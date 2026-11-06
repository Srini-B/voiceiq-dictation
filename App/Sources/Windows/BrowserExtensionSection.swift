import AppKit
import SwiftUI
import VoiceIQCore
import VoiceIQSpeech

/// The VoiceiQ Meetings Chrome extension: it tells the app which participant
/// is talking in a browser meeting (`BrowserSpeakers`). It is not on the
/// Chrome Web Store, and Chrome lets an app install nothing itself, so the app
/// copies it out and the user loads it once with Developer mode on.
enum BrowserExtension {
    /// Fixed by the manifest's `key`, so the host manifest can name it.
    static let id = "gjobkaplebdoedjfopfmogibphjmglaa"
    static let hostName = "io.blue.voiceiq.browser"
    static let nativeHostExecutable = "Contents/Helpers/VoiceiQLocalSpeech.app/Contents/MacOS/VoiceiQLocalSpeech"

    /// Where Chrome loads the unpacked extension from.
    static var folder: URL { FileLayout.appSupportRoot.appendingPathComponent("ChromeExtension", isDirectory: true) }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) }

    /// Chromium browsers read a host manifest from `<support folder>/NativeMessagingHosts`.
    private static let browserFolders = ["Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Google/Chrome for Testing",
                                         "Google/ChromeForTesting", "Chromium",
                                         "Microsoft Edge", "BraveSoftware/Brave-Browser", "Arc/User Data", "Vivaldi"]

    /// Run again after each update: Chrome needs the host's absolute path, which moves with the app.
    static func install() throws {
        guard let bundled = Bundle.main.url(forResource: "ChromeExtension", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: bundled, to: folder)
        let host = Bundle.main.bundleURL.appendingPathComponent(nativeHostExecutable)
        let manifest: [String: Any] = [
            "name": hostName, "description": "VoiceiQ Meetings", "path": host.path, "type": "stdio",
            "allowed_origins": ["chrome-extension://\(id)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for browser in browserFolders where fm.fileExists(atPath: support.appendingPathComponent(browser).path) {
            let hosts = support.appendingPathComponent(browser).appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            try fm.createDirectory(at: hosts, withIntermediateDirectories: true)
            try data.write(to: hosts.appendingPathComponent("\(hostName).json"), options: .atomic)
        }
    }

    static func refreshIfInstalled() {
        guard isInstalled else { return }
        do { try install() } catch { Log.meeting.error("browser extension refresh failed: \(String(describing: error), privacy: .public)") }
    }

    static var lastHeard: Date? {
        let logs = (try? FileManager.default.contentsOfDirectory(at: BrowserSpeakerLog.folder(root: FileLayout.appSupportRoot),
                                                                  includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return logs.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    static func showLoadSteps() {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let page = URL(string: "chrome://extensions") else { return }
        NSWorkspace.shared.open([page], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct BrowserExtensionSection: View {
    @State private var installed = BrowserExtension.isInstalled
    @State private var lastHeard = BrowserExtension.lastHeard
    @State private var failure: String?

    var body: some View {
        Section {
            LabeledContent("Status") {
                Text(status).foregroundStyle(.secondary)
            }
            if installed {
                Text("In Chrome's Extensions page, turn on Developer mode, then drag the selected ChromeExtension folder onto the page, or click Load unpacked and choose it. Chrome keeps it from then on.")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(.secondary)
            }
            if let failure {
                Text(failure).font(VoiceIQUI.TypeScale.labelSmall()).foregroundStyle(VoiceIQUI.Colors.error)
            }
            HStack {
                Button(installed ? "Show in Chrome…" : "Install in Chrome…") { install() }
                Spacer()
            }
        } header: {
            Text("Chrome extension for meetings")
        } footer: {
            Text("For Google Meet, Teams, Zoom and other calls in Chrome, Edge, Brave or Arc. The extension tells VoiceiQ which participant is talking, from the call's own audio streams, so people who sound alike are kept apart. It sends only stream numbers and times, never audio, names or page content.")
        }
        .onAppear { installed = BrowserExtension.isInstalled; lastHeard = BrowserExtension.lastHeard }
    }

    private var status: String {
        guard installed else { return "Not installed" }
        guard let lastHeard else { return "Waiting for Chrome to load it" }
        return "Working, last heard \(lastHeard.formatted(.relative(presentation: .named)))"
    }

    private func install() {
        do {
            try BrowserExtension.install()
            failure = nil; installed = true
            BrowserExtension.showLoadSteps()
        } catch {
            failure = "Couldn't copy the extension: \(error.localizedDescription)"
        }
    }
}
