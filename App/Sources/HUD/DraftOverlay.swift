import AppKit
import SwiftUI
import VoiceIQCore

/// The marks over the field a draft is in: a small spinner at the cursor
/// until the transcript lands, then a shimmering line under each of its
/// lines while the writing model rewrites it. Click-through panels above
/// the app's windows; they never take focus.
@MainActor
final class DraftOverlay: DraftMarking {
    private var spinner: NSPanel?
    private var lines: [NSPanel] = []

    static let spinnerSize: CGFloat = 16
    static let lineHeight: CGFloat = 2.5

    func showSpinner(at caret: CGRect) {
        clear()
        let size = Self.spinnerSize
        let frame = CGRect(x: caret.minX + 3, y: caret.midY - size / 2, width: size, height: size)
        let panel = Self.panel(frame: frame, content: DraftSpinner())
        panel.orderFrontRegardless()
        spinner = panel
    }

    func underline(_ rects: [CGRect]) {
        spinner?.orderOut(nil)
        spinner = nil
        while lines.count > rects.count { lines.removeLast().orderOut(nil) }
        for (index, rect) in rects.enumerated() {
            let frame = CGRect(x: rect.minX, y: rect.minY - Self.lineHeight, width: rect.width, height: Self.lineHeight)
            if index < lines.count {
                if lines[index].frame != frame { lines[index].setFrame(frame, display: false) }
            } else {
                let panel = Self.panel(frame: frame, content: DraftUnderline())
                panel.orderFrontRegardless()
                lines.append(panel)
            }
        }
    }

    func clear() {
        spinner?.orderOut(nil)
        spinner = nil
        lines.forEach { $0.orderOut(nil) }
        lines = []
    }

    private static func panel(frame: CGRect, content: some View) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.sharingType = SettingsStore().hidePillFromScreenSharing ? .none : .readOnly
        let host = NSHostingView(rootView: content.frame(maxWidth: .infinity, maxHeight: .infinity))
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }
}

/// A turning arc in the brand colors: the words are on their way.
private struct DraftSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let turn = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle()
                .trim(from: 0.08, to: 0.78)
                .stroke(AngularGradient(colors: VoiceIQUI.Colors.brandQuad + [VoiceIQUI.Colors.gBlue], center: .center),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? 0 : turn * 360))
                .padding(2)
        }
    }
}

/// The processing shimmer, travelling along the line: the text above it
/// is being written.
private struct DraftUnderline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            let colors = VoiceIQUI.Colors.aiShimmer
            GeometryReader { proxy in
                Capsule()
                    .fill(LinearGradient(colors: colors + colors.reversed() + colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * 3)
                    .offset(x: reduceMotion ? 0 : -proxy.size.width * 2 * phase)
            }
            .clipShape(Capsule())
        }
    }
}
