import AppKit
import SwiftUI
import VoiceIQCore

/// A permission the first-run checklist asks for.
enum SetupPermission: Hashable {
    case microphone, accessibility, screenRecording

    /// What to do in the System Settings pane. The microphone list already
    /// holds VoiceiQ once it has asked; the other lists may need it dragged in.
    var guide: String {
        self == .microphone ? "Turn on VoiceiQ" : "Drag VoiceiQ into the list, then turn it on"
    }
}

/// A small card beside System Settings while a permission is being granted:
/// what to do there, with the app icon to drag into the list. It never takes
/// focus, so System Settings stays the active window. The checklist closes it
/// when the grant lands, when the screen goes away, or when onboarding closes.
@MainActor
final class PermissionGuidePanel {
    static let shared = PermissionGuidePanel()

    private(set) var permission: SetupPermission?
    private var panel: NSPanel?

    func show(_ permission: SetupPermission) {
        close()
        let size = NSSize(width: 260, height: 110)
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let origin = NSPoint(x: visible.maxX - size.width - 24, y: visible.midY - size.height / 2)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // VoiceiQ is in the background the whole time this is up.
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: PermissionGuideView(permission: permission))
        panel.orderFrontRegardless()
        self.panel = panel
        self.permission = permission
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        permission = nil
    }
}

private struct PermissionGuideView: View {
    let permission: SetupPermission

    var body: some View {
        VStack(alignment: .leading, spacing: VQ.Spacing.s) {
            HStack(alignment: .top, spacing: VQ.Spacing.xs) {
                Text(permission.guide)
                    .font(GTFont.flex(VQ.TypeScale.headline.size, weight: VQ.TypeScale.headline.weight))
                    .foregroundStyle(VQ.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { PermissionGuidePanel.shared.close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(VQ.Colors.muted)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            HStack(spacing: VQ.Spacing.xs) {
                if let icon = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                        // A real file drag of the app bundle: the privacy lists
                        // accept an app dropped onto them.
                        .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                        .help("Drag into the list in System Settings")
                }
                Text("VoiceiQ")
                    .font(GTFont.flex(VQ.TypeScale.callout.size, weight: 500))
                    .foregroundStyle(VQ.Colors.ink)
                Spacer(minLength: 0)
                // The switch as it looks in System Settings before it is turned on.
                Capsule()
                    .fill(VQ.Colors.fill)
                    .overlay(Capsule().strokeBorder(VQ.Colors.hairline, lineWidth: 1))
                    .frame(width: 30, height: 18)
                    .overlay(alignment: .leading) {
                        Circle()
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                            .frame(width: 14, height: 14)
                            .padding(.leading, 2)
                    }
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .frame(width: 260, height: 110, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: VQ.Radius.card).fill(VQ.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: VQ.Radius.card).strokeBorder(VQ.Colors.hairline, lineWidth: 1))
    }
}
