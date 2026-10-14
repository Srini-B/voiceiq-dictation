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
                                LanguagePicker(selected: Binding(
                                    get: { targets[index] },
                                    set: { targets[index] = $0 }
                                )) {
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
                            LanguagePicker(selected: Binding(
                                get: { "" },
                                set: { name in
                                    if !targets.contains(name) { targets.append(name) }
                                }
                            )) {
                                save()
                                adding = false
                            }
                        }
                }
            }
        }
    }

    private func save() {
        settings.setTranslationTargetLanguages(targets)
        targets = settings.translationTargetLanguages
    }
}

struct LanguagePicker: View {
    @Binding var selected: String
    let onSelect: () -> Void
    @State private var search = ""

    private var languages: [GeminiLanguage] {
        guard !search.isEmpty else { return GeminiLanguages.supported }
        return GeminiLanguages.supported.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.code.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search languages", text: $search)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(languages) { language in
                        Button {
                            selected = language.name
                            onSelect()
                        } label: {
                            Text(language.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: VoiceIQUI.Radius.small)
                                        .fill(language.name == selected
                                              ? Color.primary.opacity(VoiceIQUI.StateLayer.hover) : .clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .padding(12)
        .frame(width: 280, height: 360)
    }
}
