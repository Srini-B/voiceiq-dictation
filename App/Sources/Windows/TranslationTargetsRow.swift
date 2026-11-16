import VoiceIQCore
import SwiftUI

/// Translate targets in order of preference, up to
/// `SettingsStore.maxTranslationTargets`. Each target is a button that opens
/// the language picker; the plus adds one; a target's close mark removes it.
/// The first target cannot be removed, so there is always one.
struct TranslationTargetsRow: View {
    @Binding var targets: [String]
    private let settings = SettingsStore()
    @State private var editing: Int?
    @State private var adding = false

    var body: some View {
        LabeledContent("Translate to") {
            HStack(spacing: 6) {
                ForEach(Array(targets.enumerated()), id: \.offset) { index, target in
                    HStack(spacing: 2) {
                        Button(target) { editing = index }
                            .popover(isPresented: Binding(
                                get: { editing == index },
                                set: { if !$0 { editing = nil } }
                            ), arrowEdge: .trailing) {
                                languages(selected: target) {
                                    targets[index] = $0
                                    save()
                                    editing = nil
                                }
                            }
                        if targets.count > 1 {
                            Button {
                                targets.remove(at: index)
                                save()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(target)")
                        }
                    }
                }
                if targets.count < SettingsStore.maxTranslationTargets {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add language")
                        .popover(isPresented: $adding, arrowEdge: .trailing) {
                            languages(selected: "") { name in
                                if !targets.contains(name) { targets.append(name) }
                                save()
                                adding = false
                            }
                        }
                }
            }
        }
    }

    private func languages(selected: String, choose: @escaping (String) -> Void) -> some View {
        SearchableList(options: GeminiLanguages.supported.map { SearchOption(value: $0.name, name: $0.name, keywords: $0.code) },
                       isSelected: { $0 == selected }, prompt: "Search languages", choose: choose)
    }

    private func save() {
        settings.setTranslationTargetLanguages(targets)
        targets = settings.translationTargetLanguages
    }
}
