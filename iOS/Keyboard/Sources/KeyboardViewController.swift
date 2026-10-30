import SwiftUI
import UIKit
import VoiceIQBridge

final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private let dictionaryOffer = DictionaryOffer()
    private let typing = TypingController()
    private var hosting: UIHostingController<KeyboardView>?
    private var height: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        model.controller = self
        dictionaryOffer.controller = self
        model.onOwnCopy = { [weak dictionaryOffer] in dictionaryOffer?.noteOwnCopy() }
        model.onInserted = { [weak typing] in typing?.refresh() }
        typing.controller = self
        requestSupplementaryLexicon { [weak typing] lexicon in
            Task { @MainActor in typing?.setSupplementaryLexicon(lexicon.entries) }
        }
        let hosting = UIHostingController(rootView: KeyboardView(model: model, offer: dictionaryOffer, typing: typing, controller: self))
        hosting.view.backgroundColor = .clear
        hosting.sizingOptions = []
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let height = view.heightAnchor.constraint(equalToConstant: typing.preferences.keyboardHeight(compact: false))
        height.priority = .defaultHigh
        height.isActive = true
        self.height = height
        hosting.didMove(toParent: self)
        self.hosting = hosting
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        HostAppResolver.keyboardWillAppear()
        model.appeared()
        dictionaryOffer.appeared(hasFullAccess: hasFullAccess)
        typing.appeared()
        // A forced key tone (and iOS 5, which has no dark look) pins the
        // whole keyboard, bar included, to light or dark.
        view.overrideUserInterfaceStyle = typing.theme.style
        updateHeight()
    }

    private func updateHeight() {
        let compact = traitCollection.verticalSizeClass == .compact
        if typing.compact != compact { typing.compact = compact }
        height?.constant = typing.preferences.keyboardHeight(compact: compact)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateHeight()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The host connection exists now, so the globe answer is reliable.
        model.refreshHostTraits()
        typing.readField()
        typing.refresh()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.disappeared()
        dictionaryOffer.disappeared()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        HostAppResolver.harvest()
        dictionaryOffer.selectionChanged()
        typing.readField()
        typing.selectionChanged()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        HostAppResolver.harvest()
        dictionaryOffer.selectionChanged()
        typing.selectionChanged()
    }

    /// Opens a URL from inside the extension. `UIApplication.open` is marked
    /// unavailable to extensions at compile time but works at runtime, so it
    /// is reached through the responder chain. `extensionContext.open` is the
    /// documented call but returns false for keyboards on current iOS.
    func openURL(_ url: URL) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector), let method = current.method(for: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                unsafeBitCast(method, to: OpenURL.self)(current, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
        extensionContext?.open(url, completionHandler: nil)
    }
}
