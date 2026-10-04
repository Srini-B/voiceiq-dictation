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
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView,
              view.textStorage?.isEqual(to: text) == false else { return }
        view.textStorage?.setAttributedString(text)
        view.scroll(.zero)
    }
}
