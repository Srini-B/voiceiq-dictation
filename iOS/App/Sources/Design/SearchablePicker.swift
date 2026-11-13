import SwiftUI

/// One choice in a `SearchablePicker`: what it sets and what it shows.
/// `keywords` are matched by the search too, such as a language code.
struct SearchOption<Value: Hashable>: Identifiable {
    let value: Value
    let name: String
    var keywords = ""
    var id: Value { value }
}

/// Every choice list in the app: a row that opens a sheet with a search
/// field on top and Done. With one value, picking closes the sheet; with
/// several, each pick toggles one and Done closes it. `hidesTitle` leaves
/// the title to the row around it; the sheet still shows it.
struct SearchablePicker<Value: Hashable>: View {
    let title: String
    let options: [SearchOption<Value>]
    let summary: String
    let isSelected: (Value) -> Bool
    let choose: (Value) -> Void
    let multiple: Bool
    let hidesTitle: Bool
    @State private var open = false

    /// One value: picking it closes the sheet.
    init(_ title: String, selection: Binding<Value>, options: [SearchOption<Value>], hidesTitle: Bool = false) {
        self.title = title; self.options = options; self.hidesTitle = hidesTitle; multiple = false
        summary = options.first { $0.value == selection.wrappedValue }?.name ?? ""
        isSelected = { $0 == selection.wrappedValue }
        choose = { selection.wrappedValue = $0 }
    }

    /// Several values: each pick toggles one and Done closes the sheet.
    init(_ title: String, summary: String, options: [SearchOption<Value>], hidesTitle: Bool = false,
         isSelected: @escaping (Value) -> Bool, toggle: @escaping (Value) -> Void) {
        self.title = title; self.options = options; self.summary = summary; self.hidesTitle = hidesTitle
        multiple = true; self.isSelected = isSelected; choose = toggle
    }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 4) {
                if !hidesTitle {
                    Text(title).foregroundStyle(Theme.Colors.ink)
                    Spacer(minLength: Theme.Spacing.s)
                }
                Group {
                    Text(summary).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.footnote)
                }
                .foregroundStyle(hidesTitle ? Theme.Colors.accent : Theme.Colors.muted)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(title): \(summary)")
        .sheet(isPresented: $open) {
            SearchableListSheet(title: title, options: options, isSelected: isSelected, multiple: multiple) { value in
                choose(value)
                if !multiple { open = false }
            }
        }
    }
}

/// The sheet behind a `SearchablePicker`: the choices under a search field,
/// with Done. With `other`, a typed name that matches no choice can be used
/// as it is; with `reset`, a Reset button undoes an earlier choice.
struct SearchableListSheet<Value: Hashable>: View {
    let title: String
    let options: [SearchOption<Value>]
    let isSelected: (Value) -> Bool
    let multiple: Bool
    let prompt: String
    let other: ((String) -> Void)?
    let reset: (() -> Void)?
    let choose: (Value) -> Void
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    init(title: String, options: [SearchOption<Value>], isSelected: @escaping (Value) -> Bool, multiple: Bool = false,
         prompt: String = "Search", other: ((String) -> Void)? = nil, reset: (() -> Void)? = nil,
         choose: @escaping (Value) -> Void) {
        self.title = title; self.options = options; self.isSelected = isSelected; self.multiple = multiple
        self.prompt = prompt; self.other = other; self.reset = reset; self.choose = choose
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private var matches: [SearchOption<Value>] {
        guard !query.isEmpty else { return options }
        return options.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.keywords.localizedCaseInsensitiveContains(query) }
    }

    private var typed: String? {
        guard other != nil, !query.isEmpty,
              !options.contains(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) else { return nil }
        return query
    }

    var body: some View {
        NavigationStack {
            List {
                if let typed {
                    Button { other?(typed) } label: { Text("Use “\(typed)”").foregroundStyle(Theme.Colors.accent) }
                }
                ForEach(matches) { option in
                    Button { choose(option.value) } label: {
                        HStack {
                            Text(option.name).foregroundStyle(Theme.Colors.ink)
                            Spacer()
                            if isSelected(option.value) {
                                Image(systemName: "checkmark").foregroundStyle(Theme.Colors.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
            .overlay {
                if matches.isEmpty && typed == nil && !query.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
            .onSubmit(of: .search) {
                if let typed { other?(typed) } else if let first = matches.first { choose(first.value) }
                if multiple { search = "" }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let reset {
                    ToolbarItem(placement: .topBarLeading) { Button("Reset", role: .destructive, action: reset) }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents(options.count > 8 || other != nil ? [.large] : [.medium, .large])
    }
}
