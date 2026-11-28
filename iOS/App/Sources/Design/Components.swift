import SwiftUI
import VoiceIQCore

// MARK: - Buttons

/// Every call to action is a pill. Primary is filled brand blue; secondary is a
/// quiet porcelain pill. Never a bare text link for a step's action.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, ink }
    var kind: Kind = .primary
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? Theme.Fonts.label() : Theme.Fonts.headline())
            .lineLimit(1)
            .padding(.horizontal, compact ? 14 : 20)
            .frame(minHeight: compact ? 34 : 52)
            .frame(maxWidth: compact ? nil : .infinity)
            .foregroundStyle(foreground)
            .background(Capsule().fill(background))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }

    private var background: Color {
        switch kind {
        case .primary: return Theme.Colors.accent
        case .secondary: return Theme.Colors.porcelain
        case .destructive: return Theme.Colors.recording.opacity(0.12)
        case .ink: return Theme.Colors.ink
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Theme.Colors.onAccent
        case .secondary: return Theme.Colors.ink
        case .destructive: return Theme.Colors.recording
        case .ink: return Theme.Colors.canvas
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var primaryPill: PillButtonStyle { PillButtonStyle(kind: .primary) }
    static var secondaryPill: PillButtonStyle { PillButtonStyle(kind: .secondary) }
    static var compactPrimary: PillButtonStyle { PillButtonStyle(kind: .primary, compact: true) }
    static var compactSecondary: PillButtonStyle { PillButtonStyle(kind: .secondary, compact: true) }
    static var compactDestructive: PillButtonStyle { PillButtonStyle(kind: .destructive, compact: true) }
}

// MARK: - Surfaces

struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.l
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.Colors.hairline, lineWidth: 1)
            )
    }
}

/// Small uppercase label above a group of cards.
struct GroupLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Fonts.caption())
            .tracking(0.6)
            .foregroundStyle(Theme.Colors.muted)
            .padding(.leading, 4)
    }
}

/// A title with optional supporting copy, for the top of a page.
struct PageTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title)
                .font(Theme.Fonts.title())
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(Theme.Fonts.callout())
                    .foregroundStyle(Theme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Brand

/// The app icon, rounded like the Home Screen shows it.
struct BrandMark: View {
    var size: CGFloat = 44

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(size > 60 ? 0.18 : 0.08), radius: size > 60 ? 18 : 4, y: size > 60 ? 8 : 2)
            .accessibilityHidden(true)
    }
}

/// "VoiceiQ" with the icon's headphones in the Q.
struct Wordmark: View {
    var height: CGFloat = 26

    var body: some View {
        Image("Wordmark")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel("VoiceiQ")
    }
}

// MARK: - Status

struct StatusChip: View {
    enum Tone { case done, pending, off, live }
    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(Theme.Fonts.caption())
        }
        .foregroundStyle(tone == .off ? Theme.Colors.muted : color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private var color: Color {
        switch tone {
        case .done: return Theme.Colors.success
        case .pending: return Theme.Colors.pending
        case .off: return Theme.Colors.muted
        case .live: return Theme.Colors.accent
        }
    }
}

/// A rounded square holding an SF Symbol, used as a row's leading icon.
struct IconTile: View {
    let systemImage: String
    var tint: Color = Theme.Colors.accent
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(tint.opacity(0.12)))
            .accessibilityHidden(true)
    }
}

/// A service's symbol on a neutral tile, in the ink colour, so it reads in
/// dark mode.
struct BrandTile: View {
    let systemImage: String
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Theme.Colors.ink)
            .frame(width: size * 0.6, height: size * 0.6)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).fill(Theme.Colors.porcelain))
            .accessibilityHidden(true)
    }
}

/// A checklist line: a state glyph, a title and an optional detail.
struct CheckLine: View {
    let title: String
    var detail: String?
    let done: Bool
    var waiting = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : waiting ? "clock" : "circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(done ? Theme.Colors.success : waiting ? Theme.Colors.pending : Theme.Colors.muted.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Fonts.callout()).foregroundStyle(Theme.Colors.ink)
                if let detail {
                    Text(detail).font(Theme.Fonts.footnote()).foregroundStyle(Theme.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Screens

extension UIDevice {
    static let isPad = current.userInterfaceIdiom == .pad
}

/// A list beside its detail where there is room (iPad); the split view collapses
/// to a stack elsewhere (iPhone, and iPad windows too narrow for two columns).
/// Side by side, the tab bar above names the page and the highlighted row
/// names the section, so neither column shows a title or a bar behind it.
struct ListDetailNavigation<Sidebar: View, Detail: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail

    var body: some View {
        let wide = sizeClass == .regular
        NavigationSplitView {
            sidebar
                // The selected row's tint marks it; no focus ring on top.
                .focusEffectDisabled()
                .modifier(BareNavigationBar(bare: wide))
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
        } detail: {
            NavigationStack { detail.modifier(BareNavigationBar(bare: wide)) }
        }
        .navigationSplitViewStyle(.balanced)
        // The split view paints the band under the tab bar itself; without
        // this it shows the system black above both columns' canvases.
        .background(Theme.Colors.canvas.ignoresSafeArea())
    }
}

extension ListDetailNavigation {
    /// A sidebar whose links push their own pages; the detail column shows
    /// `placeholder` until one is picked.
    init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder placeholder: () -> Detail) {
        self.sidebar = sidebar()
        self.detail = placeholder()
    }
}

/// No title and no bar background. Collapsed (compact width), the page keeps
/// both: the title is then the only name it has.
private struct BareNavigationBar: ViewModifier {
    let bare: Bool

    /// Removes the toolbar title on iOS 18 and later, returning the content
    /// with its title on earlier versions.
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), bare {
            content.toolbar(removing: .title).toolbarBackground(.hidden, for: .navigationBar)
        } else if bare {
            content.toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
        }
    }
}

/// The detail column before anything is picked.
struct DetailPlaceholder: View {
    let systemImage: String
    let title: String

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            IconTile(systemImage: systemImage, size: 72)
            Text(title).font(Theme.Fonts.title2()).foregroundStyle(Theme.Colors.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.canvas.ignoresSafeArea())
    }
}

extension View {
    /// Caps a page at a comfortable reading width and centers it, so wide
    /// iPad windows don't stretch cards and lines edge to edge.
    func readableWidth(_ width: CGFloat = 720) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }

    /// The light grey page behind grouped settings cards.
    func groupedBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.Colors.grouped.ignoresSafeArea())
    }

    /// The canvas behind every page, lists included.
    func themedBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.Colors.canvas.ignoresSafeArea())
    }

    /// Lets the user put the keyboard away: drag the page, or tap Done above
    /// the keyboard. The Done bar shows above any keyboard, VoiceiQ's included.
    func keyboardDismissable() -> some View {
        scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.endEditing() }
                        .font(Theme.Fonts.label())
                }
            }
    }
}

extension UIApplication {
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - Redesign components (docs/design/redesign-2026-11.md)

/// A recording's length in a hairline capsule, as on a list row.
struct DurationChip: View {
    let seconds: Double

    var body: some View {
        Label(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)), systemImage: "waveform")
            .labelStyle(.titleAndIcon)
            .font(Theme.Fonts.flex(12.5, weight: 500, style: .caption1).monospacedDigit())
            .foregroundStyle(Theme.Colors.inkSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .overlay(Capsule().strokeBorder(Theme.Colors.hairline, lineWidth: 1))
    }
}

/// The Talk key: a blue rounded square with the waveform mark. While a note
/// records it turns red with a stop square.
struct TalkKey: View {
    let recording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: VQ.Radius.talkKey, style: .continuous)
                    .fill(recording ? Theme.Colors.recording : Theme.Colors.accent)
                if recording {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white).frame(width: 18, height: 18)
                } else {
                    Image(systemName: "waveform").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.Colors.onAccent)
                }
            }
            .frame(width: 60, height: 60)
            .background(
                RoundedRectangle(cornerRadius: VQ.Radius.talkKey + 6, style: .continuous)
                    .fill(recording ? VQ.Colors.recordSoft : .clear)
                    .padding(-6)
            )
            .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(recording ? "Open the note being recorded" : "Record a note")
    }
}

/// Press feedback without a tint: a slight shrink.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A floating capsule beside the Talk key: canvas, hairline ring, one shadow.
struct DockCapsule<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.s) { label }
                .font(Theme.Fonts.callout())
                .foregroundStyle(Theme.Colors.muted)
                .lineLimit(1)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(Capsule().fill(Theme.Colors.canvas))
                .overlay(Capsule().strokeBorder(Theme.Colors.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}
