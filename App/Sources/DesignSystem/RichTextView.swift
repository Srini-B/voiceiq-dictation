import AppKit
import SwiftUI

/// Read-only, selectable, scrolling text backed by NSTextView.
///
/// SwiftUI's `Text(...).textSelection(.enabled)` builds an AppKit selection
/// overlay per view and re-measures every one on scroll, which is what froze the
/// meeting transcript at twenty minutes of text. One NSTextView holds any length
/// of text, wraps to the width it is given, and selects across paragraphs.
struct RichTextView: NSViewRepresentable {
    let text: NSAttributedString
    var inset = NSSize(width: 0, height: 0)
    /// Items put above the text view's own right-click menu, given the
    /// attributes of the character clicked.
    var menuItems: (@MainActor ([NSAttributedString.Key: Any]) -> [MenuItem])? = nil

    struct MenuItem {
        let title: String
        let action: @MainActor () -> Void
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = inset
        view.isAutomaticLinkDetectionEnabled = false
        view.linkTextAttributes = [
            .foregroundColor: NSColor(hex: 0x0B57D0),
            .cursor: NSCursor.pointingHand,
        ]
        view.textStorage?.setAttributedString(text)
        context.coordinator.menuItems = menuItems
        view.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.menuItems = menuItems
        guard let view = scroll.documentView as? NSTextView,
              view.textStorage?.isEqual(to: text) == false else { return }
        view.textStorage?.setAttributedString(text)
        view.scroll(.zero)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var menuItems: (@MainActor ([NSAttributedString.Key: Any]) -> [MenuItem])?
        private var actions: [@MainActor () -> Void] = []

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard let menuItems, let storage = view.textStorage, charIndex < storage.length else { return menu }
            let items = menuItems(storage.attributes(at: charIndex, effectiveRange: nil))
            guard !items.isEmpty else { return menu }
            actions = items.map(\.action)
            menu.insertItem(.separator(), at: 0)
            for (index, item) in items.enumerated().reversed() {
                let entry = NSMenuItem(title: item.title, action: #selector(run(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = index
                menu.insertItem(entry, at: 0)
            }
            return menu
        }

        @objc private func run(_ item: NSMenuItem) { actions[item.tag]() }
    }
}
