import AppKit
import SwiftUI

/// One choice in a `SearchablePicker`: what it sets and what it shows.
/// `keywords` are matched by the search too, such as a language code.
struct SearchOption<Value: Hashable>: Identifiable {
    let value: Value
    let name: String
    var keywords = ""
    var id: Value { value }
}

/// Every choice list in the app: a pop-up button whose list opens with a
/// search field on top. With one value, picking closes the list; with
/// several (`staysOpen`), the list stays open and shows a check by each
/// chosen value until the user clicks away or presses Return on an empty
/// search. The list opens above the button so it never covers the row
/// below, and keeps its height while the search narrows it: a popover that
/// shrinks can move to the other side of its button.
struct SearchablePicker<Value: Hashable>: View {
    let title: String
    let options: [SearchOption<Value>]
    let summary: String
    let isSelected: (Value) -> Bool
    let choose: (Value) -> Void
    let staysOpen: Bool
    @State private var open = false

    /// One value: picking it closes the list.
    init(_ title: String, selection: Binding<Value>, options: [SearchOption<Value>]) {
        self.title = title; self.options = options; staysOpen = false
        summary = options.first { $0.value == selection.wrappedValue }?.name ?? ""
        isSelected = { $0 == selection.wrappedValue }
        choose = { selection.wrappedValue = $0 }
    }

    /// Several values: each pick toggles one and the list stays open.
    init(_ title: String, summary: String, options: [SearchOption<Value>],
         isSelected: @escaping (Value) -> Bool, toggle: @escaping (Value) -> Void) {
        self.title = title; self.options = options; self.summary = summary; staysOpen = true
        self.isSelected = isSelected; choose = toggle
    }

    var body: some View {
        if title.isEmpty { button } else { LabeledContent { button } label: { Text(title) } }
    }

    private var button: some View {
        Button { open = true } label: {
            HStack(spacing: 4) {
                Text(summary).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .accessibilityLabel(title.isEmpty ? summary : "\(title): \(summary)")
        .popover(isPresented: $open, arrowEdge: .top) {
            SearchableList(options: options, isSelected: isSelected, multiple: staysOpen) { value in
                choose(value)
                if !staysOpen { open = false }
            } done: { open = false }
        }
    }
}

/// A searchable list of choices, the inside of a `SearchablePicker` popover.
/// Return picks the first match; with `other`, a typed name that matches no
/// choice can be used as it is.
struct SearchableList<Value: Hashable>: View {
    let options: [SearchOption<Value>]
    let isSelected: (Value) -> Bool
    let multiple: Bool
    let prompt: String
    let other: ((String) -> Void)?
    let choose: (Value) -> Void
    let done: () -> Void
    @State private var search = ""
    @FocusState private var searching: Bool

    init(options: [SearchOption<Value>], isSelected: @escaping (Value) -> Bool, multiple: Bool = false,
         prompt: String = "Search", other: ((String) -> Void)? = nil,
         choose: @escaping (Value) -> Void, done: @escaping () -> Void = {}) {
        self.options = options; self.isSelected = isSelected; self.multiple = multiple; self.prompt = prompt
        self.other = other; self.choose = choose; self.done = done
    }

    private var matches: [SearchOption<Value>] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return options }
        return options.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.keywords.localizedCaseInsensitiveContains(query) }
    }

    private var typed: String? {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard other != nil, !query.isEmpty, !options.contains(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) else { return nil }
        return query
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiceIQUI.Spacing.xs) {
            HStack(spacing: VoiceIQUI.Spacing.xxs) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(prompt, text: $search)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .focused($searching)
                    .onSubmit(submit)
            }
            .padding(.horizontal, VoiceIQUI.Spacing.xs)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.small).fill(Color.primary.opacity(0.06)))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let typed {
                        SearchableRow(label: "Use “\(typed)”", checked: false) { other?(typed) }
                    }
                    ForEach(matches) { option in
                        SearchableRow(label: option.name, checked: isSelected(option.value)) { choose(option.value) }
                    }
                    if matches.isEmpty && typed == nil && !(other != nil && search.isEmpty) {
                        Text("No matches").foregroundStyle(.secondary).padding(VoiceIQUI.Spacing.xs)
                    }
                }
            }
            .frame(height: min(320, CGFloat(max(1, options.count + (other == nil ? 0 : 1))) * 26), alignment: .top)
        }
        .environment(\.layoutDirection, .leftToRight)
        .padding(VoiceIQUI.Spacing.s)
        .frame(width: 260)
        .onAppear { searching = true }
        // Closing the popover would otherwise hand focus to the window's
        // first text field, such as an API key.
        .onDisappear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
    }

    /// Return picks the first match, or uses the typed name. In a list of
    /// several values it toggles only a single match, and on an empty search
    /// it closes the list.
    private func submit() {
        if search.trimmingCharacters(in: .whitespaces).isEmpty {
            if multiple { done() }
            return
        }
        if let typed { other?(typed); return }
        guard let first = matches.first, !multiple || matches.count == 1 else { return }
        choose(first.value)
        if multiple { search = "" }
    }
}

private struct SearchableRow: View {
    let label: String
    let checked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                Spacer()
                if checked { Image(systemName: "checkmark").foregroundStyle(.secondary) }
            }
            .padding(.horizontal, VoiceIQUI.Spacing.xs)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: VoiceIQUI.Radius.small)
                .fill(Color.primary.opacity(hovering ? VoiceIQUI.StateLayer.hover : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
