import SwiftUI
import UIKit
import VoiceIQBridge

/// Offers to add a word to the dictionary: the text selected in the field
/// the keyboard is typing into, or, for text selected anywhere else (a web
/// page, a message), what the user just copied.
///
/// A keyboard sees only its own field. Text selected elsewhere reaches it
/// through the clipboard, so a fresh copy is offered once, on the next
/// keyboard appearance. The app does the adding (`DictionaryBridge`).
@MainActor
final class DictionaryOffer: ObservableObject {
    enum Offer: Equatable {
        case selection(String, saved: Bool)
        case copied
    }

    @Published private(set) var offer: Offer?
    @Published private(set) var feedback: String?

    weak var controller: UIInputViewController?
    private let store = SharedStore.shared
    private var enabled = false
    private var copiedPending = false
    /// Added from this keyboard and not yet in the app's published list.
    private var justAdded: Set<String> = []
    private var feedbackTask: Task<Void, Never>?
    private static let seenPasteboardKey = "seenPasteboardChangeCount"

    func appeared(hasFullAccess: Bool) {
        // Without Full Access nothing reaches the app, and reading the
        // clipboard is not allowed.
        enabled = hasFullAccess
        let pasteboard = UIPasteboard.general
        let seen = UserDefaults.standard.object(forKey: Self.seenPasteboardKey) as? Int
        copiedPending = hasFullAccess
            && pasteboard.changeCount != seen
            && pasteboard.changeCount != store.appPasteboardChangeCount
            && pasteboard.hasStrings
        update()
    }

    /// A copy is offered on one appearance only.
    func disappeared() {
        if copiedPending { markPasteboardSeen() }
        copiedPending = false
    }

    func selectionChanged() { update() }

    func add() {
        switch offer {
        case .selection(let term, saved: false):
            save(term)
        default:
            break
        }
        update()
    }

    /// The clipboard's text, handed over by the system paste button: iOS
    /// lets a keyboard read another app's copy only through that button.
    func addCopied(_ strings: [String]) {
        markPasteboardSeen()
        copiedPending = false
        if let term = DictionaryAddition.candidate(from: strings.first) {
            isSaved(term) ? show("“\(term)” is already in your Dictionary") : save(term)
        } else {
            show("Copy a word or name of up to 60 characters")
        }
        update()
    }

    /// Our own copies (Ask's Copy) are not offered back.
    func noteOwnCopy() {
        markPasteboardSeen()
        copiedPending = false
        update()
    }

    private func update() {
        let next: Offer?
        if !enabled {
            next = nil
        } else if let term = DictionaryAddition.candidate(from: controller?.textDocumentProxy.selectedText) {
            next = .selection(term, saved: isSaved(term))
        } else {
            next = copiedPending ? .copied : nil
        }
        if next != offer { offer = next }
    }

    private func isSaved(_ term: String) -> Bool {
        let key = term.lowercased()
        return justAdded.contains(key) || store.dictionaryTerms.contains(key)
    }

    private func save(_ term: String) {
        store.requestDictionaryAddition(term)
        justAdded.insert(term.lowercased())
        KeyboardLog.note("dictionary word queued")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        show("Added “\(term)” to your Dictionary")
    }

    private func markPasteboardSeen() {
        UserDefaults.standard.set(UIPasteboard.general.changeCount, forKey: Self.seenPasteboardKey)
    }

    private func show(_ text: String) {
        feedback = text
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.feedback = nil
        }
    }
}

/// The offer as a small capsule under the mic bar.
struct DictionaryOfferChip: View {
    static let height: CGFloat = 36

    @ObservedObject var offer: DictionaryOffer

    var body: some View {
        Group {
            if let feedback = offer.feedback {
                Label(feedback, systemImage: "checkmark")
                    .foregroundStyle(.secondary)
            } else if offer.offer == .copied {
                // iOS fixes the paste button at about 34pt tall, whatever
                // the control size, so the capsule is sized to hold it.
                HStack(spacing: 8) {
                    Text("Add copied text to Dictionary")
                    // The system paste button: the only way a keyboard may
                    // read what another app copied, and it asks nothing.
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in offer.addCopied(strings) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
                .padding(.leading, 14)
                .padding(.trailing, 1)
                .frame(height: DictionaryOfferChip.height)
                .background(Capsule().fill(Color(.secondarySystemFill)))
            } else if let current = offer.offer {
                Button(action: offer.add) {
                    Label(title(current), systemImage: saved(current) ? "checkmark" : "plus")
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(Color(.secondarySystemFill)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(saved(current) ? Color.secondary : Color.primary)
                .disabled(saved(current))
            }
        }
        .font(.system(size: 13, weight: .medium))
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 320)
    }

    private func title(_ offer: DictionaryOffer.Offer) -> String {
        switch offer {
        case .selection(let term, saved: true): return "“\(term)” is in your Dictionary"
        case .selection(let term, saved: false): return "Add “\(term)” to Dictionary"
        case .copied: return ""
        }
    }

    private func saved(_ offer: DictionaryOffer.Offer) -> Bool {
        if case .selection(_, saved: true) = offer { return true }
        return false
    }
}

