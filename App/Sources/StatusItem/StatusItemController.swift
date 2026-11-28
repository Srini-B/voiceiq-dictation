import AppKit
import CoreAudio
import VoiceIQCore

/// Owns the NSStatusItem. Plain NSStatusItem (not MenuBarExtra) so the template
/// icon can pulse for listening and processing states.
@MainActor
final class StatusItemController: NSObject {
    enum VisualState {
        case idle
        case listening
        case processing
        case attention // permission missing / key invalid
    }

    private let statusItem: NSStatusItem
    private let onOpenHistory: () -> Void
    private let onPasteLast: () -> Void
    private let onOpenSettings: () -> Void
    private let onAddToDictionary: () -> Void
    private let onStartHandsFree: () -> Void
    private let onOpenAbout: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onJoinMeeting: (CalendarMeetings.Upcoming) -> Void
    private let nextMeetingButton: (CalendarMeetings.Upcoming) -> NextMeetingButton?
    private let templateImage: NSImage
    private var animationTimer: Timer?
    private var animationStartedAt = Date()
    private var state: VisualState = .idle

    init(
        onOpenHistory: @escaping () -> Void,
        onPasteLast: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onAddToDictionary: @escaping () -> Void,
        onStartHandsFree: @escaping () -> Void,
        onOpenAbout: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onJoinMeeting: @escaping (CalendarMeetings.Upcoming) -> Void,
        nextMeetingButton: @escaping (CalendarMeetings.Upcoming) -> NextMeetingButton?
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.onOpenHistory = onOpenHistory
        self.onPasteLast = onPasteLast
        self.onOpenSettings = onOpenSettings
        self.onAddToDictionary = onAddToDictionary
        self.onStartHandsFree = onStartHandsFree
        self.onOpenAbout = onOpenAbout
        self.onCheckForUpdates = onCheckForUpdates
        self.onJoinMeeting = onJoinMeeting
        self.nextMeetingButton = nextMeetingButton
        self.templateImage = Self.loadTemplateImage()
        super.init()

        statusItem.button?.image = templateImage
        statusItem.button?.toolTip = "VoiceiQ"
        statusItem.menu = makeMenu()
    }

    func setState(_ newState: VisualState) {
        guard newState != state else { return }
        state = newState
        animationTimer?.invalidate()
        animationTimer = nil
        animationStartedAt = Date()

        switch newState {
        case .idle:
            statusItem.button?.alphaValue = 1
        case .attention:
            statusItem.button?.alphaValue = 0.4
        case .listening, .processing:
            // Pulse the button's alpha rather than redrawing the image: a fresh
            // NSImage per frame at 30 fps made the status item re-measure and
            // recommit its scene on every tick for the whole dictation.
            animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
                // Scheduled on the main run loop, so it fires on the main thread.
                MainActor.assumeIsolated { self?.tickAnimation() }
            }
            tickAnimation()
        }
    }

    private func tickAnimation() {
        let duration = state == .listening ? 0.7 : 1.2
        let phase = Date().timeIntervalSince(animationStartedAt) / duration * 2 * Double.pi
        statusItem.button?.alphaValue = 0.725 + 0.275 * CGFloat(sin(phase))
    }

    private static func loadTemplateImage() -> NSImage {
        guard let bundled = Bundle.main.image(forResource: "MenuBarIcon"),
              let image = bundled.copy() as? NSImage else { return NSImage(size: NSSize(width: 18, height: 18)) }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    // MARK: - Menu

    private var statusLine: NSMenuItem?
    private var updatesItem: NSMenuItem?
    /// The next calendar meeting: a separator, a header with when it starts,
    /// its title and, when the invite has a call link, Join.
    private var nextMeetingItems: [NSMenuItem] = []

    func setStatusLine(_ text: String) {
        statusLine?.title = text
    }

    func setAvailableUpdate(_ update: AppUpdater.AvailableUpdate?) {
        switch update {
        case nil: updatesItem?.title = "Check for Updates…"
        case .found(let version): updatesItem?.title = "Install VoiceiQ \(version)…"
        case .downloaded(let version): updatesItem?.title = "Restart to Install VoiceiQ \(version)"
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(title: "Starting up…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusLine = status
        menu.addItem(status)
        // So a test run's switches cannot stay on unnoticed.
        for (on, title) in [(CloudSync.isDisabledForTests, "Sync off (test)"), (FileLayout.testDataFolder != nil, "Test data folder")] where on {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        let nextTitle = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        nextTitle.isEnabled = false
        let join = NSMenuItem(title: "", action: #selector(joinNextMeeting(_:)), keyEquivalent: "")
        join.target = self
        nextMeetingItems = [.separator(), .sectionHeader(title: ""), nextTitle, join]
        nextMeetingItems.forEach { $0.isHidden = true; menu.addItem($0) }

        menu.addItem(.separator())

        let handsFree = NSMenuItem(title: "Start Hands-Free Dictation", action: #selector(startHandsFree), keyEquivalent: "")
        handsFree.target = self
        menu.addItem(handsFree)

        let pasteLast = NSMenuItem(title: "Paste Last Transcript", action: #selector(pasteLastTranscript), keyEquivalent: "")
        pasteLast.target = self
        menu.addItem(pasteLast)

        let history = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        let addWord = NSMenuItem(title: "Add to Dictionary…", action: #selector(addToDictionary), keyEquivalent: "")
        addWord.target = self
        menu.addItem(addWord)

        menu.addItem(.separator())

        // Which mic VoiceiQ hears through — moves the SYSTEM default input, exactly
        // like Control Center, so AirPods vs built-in is one click (dogfood).
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micMenu = NSMenu(title: "Microphone")
        micMenu.delegate = self
        micItem.submenu = micMenu
        menu.addItem(micItem)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About VoiceiQ", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updatesItem = updates
        menu.addItem(updates)

        let quit = NSMenuItem(title: "Quit VoiceiQ", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        return menu
    }

    /// Read when the menu opens, so it is never stale.
    private func showNextMeeting() {
        let next = CalendarMeetings.next(after: Date())
        let header = nextMeetingItems[1], title = nextMeetingItems[2], join = nextMeetingItems[3]
        nextMeetingItems.forEach { $0.isHidden = next == nil }
        guard let next else { return }
        header.title = "Next Meeting · \(CalendarMeetings.when(next.start, now: Date()))"
        title.title = next.title
        let button = nextMeetingButton(next)
        join.isHidden = button == nil
        join.title = button?.title ?? ""
        // The menu enables an item by its action: none greys out In Progress.
        join.action = button?.enabled == true ? #selector(joinNextMeeting(_:)) : nil
        join.representedObject = next
    }

    @objc private func openHistory() {
        onOpenHistory()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func addToDictionary() {
        onAddToDictionary()
    }

    @objc private func startHandsFree() {
        onStartHandsFree()
    }

    @objc private func pasteLastTranscript() {
        onPasteLast()
    }

    @objc private func openAbout() {
        onOpenAbout()
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates()
    }

    @objc private func joinNextMeeting(_ sender: NSMenuItem) {
        guard let meeting = sender.representedObject as? CalendarMeetings.Upcoming else { return }
        onJoinMeeting(meeting)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AudioDeviceID else { return }
        AudioInputDevices.setDefault(id: id)
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu { showNextMeeting() }
    }

    /// Rebuild the Microphone submenu each open — devices come and go
    /// (AirPods connect, headsets unplug) and the checkmark must be live.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Microphone" else { return }
        menu.removeAllItems()
        let current = AudioInputDevices.currentDefaultID()
        let devices = AudioInputDevices.list()
        if devices.isEmpty {
            let none = NSMenuItem(title: "No microphones found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id
            item.state = device.id == current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let note = NSMenuItem(title: "Sets your Mac's input device", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
    }
}
