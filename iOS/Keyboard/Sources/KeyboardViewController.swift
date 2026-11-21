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
        model.onOwnCopy = { [weak dictionaryOffer] in dictionaryOffer?.noteOwnCopy() }
        model.onEdited = { [weak typing] in typing?.editedOutsideKeys() }
        typing.controller = self
        typing.onHeightChange = { [weak self] in self?.updateHeight() }
        // The Hex key starts VoiceiQ's dictation, as the mic button does; lifting
        // it after a hold finishes the dictation it started.
        typing.dictation.onDictateTap = { [weak model] in model?.micTapped() }
        typing.dictation.onStopTap = { [weak model] in model?.holdReleased() }
        typing.dictation.onOpenURL = { [weak self] url in self?.openURL(url) }
        // UIKit calls back on its own queue.
        requestSupplementaryLexicon { @Sendable [weak typing] lexicon in
            Task { @MainActor in
                typing?.setSupplementaryLexicon(lexicon.entries.map { ($0.userInput, $0.documentText) })
            }
        }
        let hosting = UIHostingController(rootView: KeyboardView(model: model, offer: dictionaryOffer, typing: typing))
        // Not clear: iOS drops a keyboard's touches that land on fully
        // transparent pixels, so taps beside a suggestion's letters and
        // between keys did nothing. 1% gray is invisible.
        hosting.view.backgroundColor = UIColor(white: 0.5, alpha: 0.01)
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
        let height = view.heightAnchor.constraint(equalToConstant: KeyboardView.barHeight(compact: false) + typing.keysHeight)
        height.priority = .defaultHigh
        height.isActive = true
        self.height = height
        hosting.didMove(toParent: self)
        self.hosting = hosting
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (controller: KeyboardViewController, _) in
            controller.updateHeight()
        }
    }

    /// iOS keeps this controller's view alive after the controller goes,
    /// through the trait collection of the SwiftUI view inside it, so every
    /// dismissal left a whole keyboard behind (14 MB each) until iOS ended
    /// the extension and showed its own keyboard. Detaching it frees it.
    deinit {
        let hosting = hosting
        MainActor.assumeIsolated { hosting?.view.removeFromSuperview() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        HostAppResolver.keyboardWillAppear()
        model.appeared()
        dictionaryOffer.appeared(hasFullAccess: hasFullAccess)
        typing.appeared()
        updateHeight()
    }

    private func updateHeight() {
        let compact = traitCollection.verticalSizeClass == .compact
        if typing.compact != compact { typing.compact = compact }
        height?.constant = typing.showsMini ? miniHeight(compact: compact)
            : KeyboardView.barHeight(compact: compact) + typing.keysHeight
    }

    /// The mic bar over two rows of keys.
    private func miniHeight(compact: Bool) -> CGFloat {
        KeyboardView.miniBarHeight(compact: compact) + (compact ? 76 : 100)
    }

    /// iOS ends a keyboard over its memory limit and shows its own.
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        typing.releaseMemory()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The host connection exists now, so the globe answer is reliable.
        model.refreshHostTraits()
        // The window's system-gesture recognizers hold back touches near the
        // screen edges, so q, a, z and p type late or not at all (azooKey,
        // giellakbd-ios). The window is the extension's own.
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
        typing.keyboard?.warmUpTextCheckerAsync()
        typing.readField()
        typing.refresh()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.disappeared()
        dictionaryOffer.disappeared()
        typing.publishLearnedWords()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        HostAppResolver.harvest()
        typing.textChanged()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        HostAppResolver.harvest()
        typing.textChanged()
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
