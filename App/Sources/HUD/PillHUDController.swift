import AppKit
import Combine
import SwiftUI
import VoiceIQCore

/// Owns the non-activating NSPanel that hosts the pill. Fixed-size panel; the pill
/// animates its own bounds inside (avoids NSWindow frame-animation jank).
/// The panel never becomes key except transiently for the locked-state stop button.
@MainActor
final class PillHUDController {
    let model = PillModel()
    private let panel: NSPanel
    private var stateObservation: AnyCancellable?
    private var mouseMonitor: Any?
    private let settings = SettingsStore()
    private var dragObservers: [NSObjectProtocol] = []
    private var grabOffset: CGFloat?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 96),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        applyScreenSharingPrivacy()
        panel.contentView = NSHostingView(
            rootView: PillRootView(model: model)
        )
        stateObservation = model.$state.sink { [weak self] _ in
            self?.reposition()
        }
        dragObservers = [
            NotificationCenter.default.addObserver(forName: .pillDragMoved, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.followGrip() }
            },
            NotificationCenter.default.addObserver(forName: .pillDragEnded, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.snapToNearestAnchor() }
            },
        ]
        reposition()
    }

    /// Slides the panel with the pointer while the grip is held. The offset
    /// between pointer and panel origin is fixed on the first move so the pill
    /// does not jump under the cursor.
    private func followGrip() {
        let mouseX = NSEvent.mouseLocation.x
        if grabOffset == nil { grabOffset = mouseX - panel.frame.origin.x }
        var origin = panel.frame.origin
        origin.x = mouseX - (grabOffset ?? 0)
        panel.setFrameOrigin(origin)
    }

    /// Lands the panel on the nearest anchor after a drag and keeps it there.
    private func snapToNearestAnchor() {
        grabOffset = nil
        guard let screen = panel.screen ?? targetScreen() else { return }
        let visible = screen.visibleFrame
        let fraction = (panel.frame.midX - visible.minX) / max(1, visible.width)
        settings.setPillAnchor(fraction)
        model.anchor = settings.pillAnchor
        let target = NSRect(origin: origin(on: screen), size: panel.frame.size)
        panel.setFrame(target, display: true, animate: true)
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
        followMouse()
    }

    /// Called at each session start so the pill follows the display the user is
    /// actually dictating on (audit L14 — it used to stick to the launch screen).
    func repositionToActiveScreen() {
        reposition()
    }

    func hide() {
        stopFollowingMouse()
        panel.orderOut(nil)
    }

    /// `.none` leaves the panel out of other apps' screen captures (Zoom, Meet,
    /// Teams, screen recorders) while it stays visible on this Mac.
    func applyScreenSharingPrivacy() {
        panel.sharingType = settings.hidePillFromScreenSharing ? .none : .readOnly
    }

    /// While the pill is up it lives on whichever display the pointer is on.
    /// People dictate into one screen and glance at another to read from it;
    /// the pill goes with the glance so it is never behind them.
    private func followMouse() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            guard let self, let screen = Self.screenUnderMouse(),
                  screen.frame != self.panel.screen?.frame else { return }
            self.place(on: screen)
        }
    }

    private func stopFollowingMouse() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    private func reposition() {
        guard let screen = targetScreen() else { return }
        place(on: screen)
    }

    /// The bottom of `screen`, at the anchor the user chose.
    private func place(on screen: NSScreen) {
        panel.setFrameOrigin(origin(on: screen))
    }

    /// The panel is wider than the pill, and the pill hugs the panel edge the
    /// anchor points at (`PillRootView`), so at 0 and 1 the pill itself
    /// touches the screen edge rather than the panel's empty margin.
    private func origin(on screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame
        let width = panel.frame.width
        let wanted = frame.minX + frame.width * settings.pillAnchor - width / 2
        let x = min(max(wanted, frame.minX), frame.maxX - width)
        return NSPoint(x: x, y: frame.minY + 16)
    }

    /// The display under the pointer, which is where the eyes are. The screen
    /// hosting the focused window is only a fallback for when the pointer is
    /// off every display (mid-drag between screens, headless remote session).
    private func targetScreen() -> NSScreen? {
        Self.screenUnderMouse() ?? Self.screenOfFocusedWindow() ?? NSScreen.main
    }

    private static func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(point) })
    }

    /// Screen hosting the frontmost app's front window, via the window list —
    /// a local syscall, never an AX round-trip into the target app. The AX
    /// version could block ~100ms per attribute on a busy app, and this runs
    /// on the key-press path where the pill must appear instantly (dogfood).
    private static func screenOfFocusedWindow() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // The list is front-to-back; the first normal-layer window owned by the
        // frontmost app is its focused/front window.
        guard let info = windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
                && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0
        }), let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
            return nil
        }
        let midX = (bounds["X"] ?? 0) + (bounds["Width"] ?? 0) / 2
        let midY = (bounds["Y"] ?? 0) + (bounds["Height"] ?? 0) / 2
        // Window-list coords are top-left-origin global; flip into Cocoa space.
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoaPoint = NSPoint(x: midX, y: primary.frame.maxY - midY)
        return NSScreen.screens.first(where: { $0.frame.contains(cocoaPoint) })
    }
}

private struct PillRootView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            PillView(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .padding(.bottom, 8)
        .padding(.horizontal, 8)
    }

    private var alignment: Alignment {
        if model.anchor <= 0 { return .bottomLeading }
        if model.anchor >= 1 { return .bottomTrailing }
        return .bottom
    }
}
