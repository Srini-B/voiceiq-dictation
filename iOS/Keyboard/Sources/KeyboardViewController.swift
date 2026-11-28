import SwiftUI
import UIKit
import VoiceIQBridge

final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private let dictionaryOffer = DictionaryOffer()
    private let editor = EditController()
    private let typing = TypingBridge()
    private var hosting: UIHostingController<KeyboardView>?
    private var backdrop: KeyboardBackdropView?
    private var height: NSLayoutConstraint?

    private static var onScreen = KeyboardsOnScreen()
    private static var lastKeyboardID = 0
    private let keyboardID: Int = {
        KeyboardViewController.lastKeyboardID += 1
        return KeyboardViewController.lastKeyboardID
    }()

    /// Adopts `UIInputViewAudioFeedback` on the root input view so `UIDevice.playInputClick()`
    /// plays system key clicks when enabled in iOS Settings.
    override func loadView() {
        super.loadView()
        let system = inputView
        let input = KeyboardInputView(frame: system?.frame ?? .zero, inputViewStyle: system?.inputViewStyle ?? .keyboard)
        input.allowsSelfSizing = system?.allowsSelfSizing ?? false
        input.autoresizingMask = system?.autoresizingMask ?? []
        input.translatesAutoresizingMaskIntoConstraints = system?.translatesAutoresizingMaskIntoConstraints ?? true
        inputView = input
        if viewIfLoaded !== input { view = input }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.controller = self
        model.editor = editor
        model.onDidInsertDictation = { [weak typing] text, before, after in
            typing?.didInsertDictation(text, before: before, after: after)
        }
        editor.controller = self
        editor.onExternalEdit = { [weak typing] in typing?.textDidChange() }
        editor.willEdit = { [weak model] in model?.userWillEdit() }
        editor.markedTextThisTurn = { [weak model] in model?.markedTextThisTurn ?? false }
        typing.controller = self
        typing.editor = editor
        typing.textBeforeWithDraft = { [weak model] in model?.textBeforeWithDraft }
        typing.onPreferredHeightChange = { [weak self] in self?.updateHeight() }
        typing.dictation.onDictateTap = { [weak model] in model?.micTapped() }
        typing.dictation.onOpenURL = { [weak self] url in self?.openURL(url) }

        requestSupplementaryLexicon { @Sendable [weak typing] lexicon in
            Task { @MainActor in
                typing?.loadLexicon(lexicon)
            }
        }

        let hosting = UIHostingController(
            rootView: KeyboardView(model: model, offer: dictionaryOffer, editor: editor, typing: typing)
        )
        // Not clear: iOS drops a keyboard's touches that land on fully
        // transparent pixels, so taps between keys did nothing. 1% gray is
        // invisible.
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
        let height = view.heightAnchor.constraint(equalToConstant: typing.keysHeight)
        height.priority = .defaultHigh
        height.isActive = true
        self.height = height
        hosting.didMove(toParent: self)
        self.hosting = hosting
        (inputView as? KeyboardInputView)?.noteHexSubview(hosting.view)

        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (self: Self, _: UITraitCollection) in
            self.updateHeight()
        }
    }

    /// iOS keeps this controller's view alive after the controller goes,
    /// through the trait collection of the SwiftUI view inside it, so every
    /// dismissal left a whole keyboard behind (14 MB each) until iOS ended
    /// the extension and showed its own keyboard. Detaching it frees it.
    deinit {
        let id = keyboardID
        MainActor.assumeIsolated {
            KeyboardViewController.onScreen.disappeared(id)
            hosting?.view.removeFromSuperview()
            backdrop?.removeFromSuperview()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        HostAppResolver.keyboardWillAppear()
        // Before the model: a result it types while appearing keeps its undo step.
        editor.appeared()
        model.appeared()
        dictionaryOffer.appeared(hasFullAccess: hasFullAccess)
        typing.appeared()
        Self.onScreen.appeared(keyboardID, in: TypingLogTraits.documentIdentifier(of: textDocumentProxy))
        updateBackdrop()
        updateHeight()
    }

    private func updateHeight() {
        let compact = traitCollection.verticalSizeClass == .compact
        if typing.compact != compact { typing.compact = compact }
        let keys = typing.keysHeight
        if height?.constant != keys { height?.constant = keys }
    }

    /// Hex's keyboard learns its new orientation from its own traits, after this
    /// controller's trait change, so the height is checked again once it has laid out.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeight()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        typing.handleMemoryWarning()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The host connection exists now, so the globe answer is reliable.
        model.refreshHostTraits()
        typing.didAppear()
        updateHeight()
        // The window's system-gesture recognizers hold back touches near the
        // screen edges, so outer keys respond late (azooKey, giellakbd-ios).
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
        editor.textChanged()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // While the text connection still reaches the field.
        model.willDisappear()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        Self.onScreen.disappeared(keyboardID)
        updateBackdrop()
        model.disappeared()
        dictionaryOffer.disappeared()
        typing.disappeared()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        HostAppResolver.harvest()
        Self.onScreen.moved(keyboardID, to: TypingLogTraits.documentIdentifier(of: textDocumentProxy))
        updateBackdrop()
        model.hostChanged()
        editor.textChanged()
        typing.textDidChange()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        HostAppResolver.harvest()
        model.hostChanged()
        editor.textChanged()
        typing.textDidChange()
    }

    /// Covers Apple's keyboard when iOS keeps an earlier extension instance
    /// underneath this one in an input-accessory field.
    private func updateBackdrop() {
        let needsBackdrop = Self.onScreen.isOverAnother(keyboardID)
        if needsBackdrop, backdrop == nil, let hostView = hosting?.view {
            let cover = KeyboardBackdropView(frame: view.bounds)
            cover.translatesAutoresizingMaskIntoConstraints = false
            view.insertSubview(cover, belowSubview: hostView)
            NSLayoutConstraint.activate([
                cover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                cover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                cover.topAnchor.constraint(equalTo: view.topAnchor),
                cover.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            backdrop = cover
            (inputView as? KeyboardInputView)?.noteHexSubview(cover)
        } else if !needsBackdrop, let cover = backdrop {
            cover.removeFromSuperview()
            backdrop = nil
        }
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
