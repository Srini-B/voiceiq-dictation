import AppKit
import SwiftUI
import VoiceIQCore
import VoiceIQSpeech

/// The VoiceiQ Meetings Chrome extension: it tells the app which participant
/// is talking in a browser meeting (`BrowserSpeakers`). It is not on the
/// Chrome Web Store, and Chrome lets an app install nothing itself, so the app
/// copies it out and the user loads it once with Developer mode on. Each
/// VoiceiQ update copies it out again and the extension reloads itself.
enum BrowserExtension {
    /// Fixed by the manifest's `key`, so the host manifest can name it.
    static let id = "gjobkaplebdoedjfopfmogibphjmglaa"
    static let hostName = "io.blue.voiceiq.browser"
    static let nativeHostExecutable = "Contents/Helpers/VoiceiQLocalSpeech.app/Contents/MacOS/VoiceiQLocalSpeech"

    /// Where Chrome loads the unpacked extension from.
    static var folder: URL { FileLayout.appSupportRoot.appendingPathComponent("ChromeExtension", isDirectory: true) }
    static var isCopiedOut: Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) }

    /// Run again after each update: Chrome needs the host's absolute path, which moves with the app.
    static func install() throws {
        guard let bundled = Bundle.main.url(forResource: "ChromeExtension", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fm = FileManager.default
        // Swapped in whole: the running extension reloads itself when the
        // version on disk changes, and must never read a half-copied folder.
        let fresh = folder.deletingLastPathComponent().appendingPathComponent("ChromeExtension.new", isDirectory: true)
        try? fm.removeItem(at: fresh)
        try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: bundled, to: fresh)
        if fm.fileExists(atPath: folder.path) {
            _ = try fm.replaceItemAt(folder, withItemAt: fresh)
        } else {
            try fm.moveItem(at: fresh, to: folder)
        }
        let host = Bundle.main.bundleURL.appendingPathComponent(nativeHostExecutable)
        let manifest: [String: Any] = [
            "name": hostName, "description": "VoiceiQ Meetings", "path": host.path, "type": "stdio",
            "allowed_origins": ["chrome-extension://\(id)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var browsers: [String] = []
        for browser in BrowserExtensionInstalls.browserFolders where fm.fileExists(atPath: support.appendingPathComponent(browser).path) {
            let hosts = support.appendingPathComponent(browser).appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            try fm.createDirectory(at: hosts, withIntermediateDirectories: true)
            try data.write(to: hosts.appendingPathComponent("\(hostName).json"), options: .atomic)
            browsers.append(browser)
        }
        Log.meeting.info("browser extension copied out; host registered for \(browsers.joined(separator: ", "), privacy: .public)")
    }

    static func refreshIfInstalled() {
        guard isCopiedOut else { return }
        do { try install() } catch { Log.meeting.error("browser extension refresh failed: \(String(describing: error), privacy: .public)") }
    }

    /// The browser profiles that have the extension, from their own records.
    static var installs: [BrowserExtensionInstall] {
        BrowserExtensionInstalls.find(id: id, support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    /// The version this VoiceiQ copies out.
    static var bundledVersion: String? {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "ChromeExtension"),
              let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String
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
    @State private var copied = BrowserExtension.isCopiedOut
    @State private var installs: [BrowserExtensionInstall] = []
    @State private var failure: String?

    var body: some View {
        Section {
            LabeledContent("Status") {
                // Chrome changes its profiles and the native host writes the
                // log without telling the app, so look again every few
                // seconds: removing the extension in Chrome shows here, and
                // "a minute ago" keeps counting.
                TimelineView(.periodic(from: .now, by: 3)) { context in
                    Text(status).foregroundStyle(.secondary)
                        .onChange(of: context.date) { installs = BrowserExtension.installs }
                }
            }
            if let note = runningNote {
                Text(note).font(VoiceIQUI.TypeScale.labelSmall()).foregroundStyle(.secondary)
            }
            if copied && enabled.isEmpty {
                Text("In Chrome's Extensions page, turn on Developer mode, then drag the selected ChromeExtension folder onto the page, or click Load unpacked and choose it. Chrome keeps it from then on, and it updates itself with VoiceiQ.")
                    .font(VoiceIQUI.TypeScale.labelSmall())
                    .foregroundStyle(.secondary)
            }
            if let failure {
                Text(failure).font(VoiceIQUI.TypeScale.labelSmall()).foregroundStyle(VoiceIQUI.Colors.error)
            }
            HStack {
                Button(installs.isEmpty ? "Install in Chrome…" : "Show in Chrome…") { install() }
                Spacer()
            }
        } header: {
            Text("Chrome extension for meetings")
        } footer: {
            Text("For Google Meet, Teams, Zoom and other calls in Chrome, Edge, Brave or Arc. The extension tells VoiceiQ which participant is talking, from the call's own audio streams, so people who sound alike are kept apart, and on Meet, Teams, Zoom and Jitsi the name the call shows on that person's tile, so the transcript uses real names. On Meet it also sends the names on every tile, so VoiceiQ knows how many people to expect. It sends stream numbers, those names, times, a few numbers about the call's audio, the tab's number and the page's address without its query, such as meet.google.com/abc-defg-hij, never audio or other page content. VoiceiQ keeps these reports on this Mac for a week, and a meeting keeps its own until you delete it.")
        }
        .onAppear { copied = BrowserExtension.isCopiedOut; installs = BrowserExtension.installs }
    }

    private var enabled: [BrowserExtensionInstall] { installs.filter(\.enabled) }

    private static func place(_ install: BrowserExtensionInstall) -> String {
        let browser = install.browser.split(separator: "/").last.map(String.init) ?? install.browser
        let profile = install.profileName.map { "\($0) (\(install.profile))" } ?? install.profile
        return "\(browser == "User Data" ? "Arc" : browser), \(profile)"
    }

    private var status: String {
        guard !installs.isEmpty else { return copied ? "Not added to Chrome" : "Not installed" }
        guard !enabled.isEmpty else { return "Turned off in \(installs.map(Self.place).joined(separator: "; "))" }
        let places = enabled.map(Self.place).joined(separator: "; ")
        guard let lastHeard = BrowserExtension.lastHeard else { return "On in \(places)" }
        return "On in \(places). Last heard from it \(lastHeard.formatted(.relative(presentation: .named)))"
    }

    /// The newest report came from an older copy than this VoiceiQ ships. The
    /// report may be from a profile that since removed the extension, so the
    /// note speaks of the last report. From 1.2 the
    /// extension reloads itself once no call is open; 1.1 and older cannot,
    /// and Chrome swaps them only when it next starts (their service worker
    /// had another file name).
    private var runningNote: String? {
        guard !enabled.isEmpty, let bundled = BrowserExtension.bundledVersion,
              let latest = BrowserSpeakerLog.latest(root: FileLayout.appSupportRoot) else { return nil }
        if latest.page != "hello", latest.version != nil, latest.probe == nil {
            return "A meeting page open since before the extension updated still reports the old way. Reload that page when its call is over."
        }
        guard let running = latest.version else {
            return "The extension last reported from an older copy than \(bundled). Chrome switches to \(bundled) the next time it starts."
        }
        return running == bundled ? nil : "The extension last reported as version \(running). It updates itself to \(bundled) once no call is open."
    }

    private func install() {
        do {
            try BrowserExtension.install()
            failure = nil; copied = true
            BrowserExtension.showLoadSteps()
        } catch {
            failure = "Couldn't copy the extension: \(error.localizedDescription)"
        }
    }
}
