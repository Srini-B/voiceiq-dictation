import SwiftUI

/// Emoji by category, recent ones first, scrolled sideways like the iOS
/// keyboard. The list is Unicode's, in CLDR order (`emoji.txt`).
struct EmojiPanel: View {
    @ObservedObject var typing: TypingController
    @State private var recents: [String] = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
    @State private var group = 0

    private static let recentsKey = "typing.recentEmoji"
    private static let groups: [(name: String, emoji: [String])] = {
        guard let url = Bundle.main.url(forResource: "emoji", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), parts[1].split(separator: " ").map(String.init))
        }
    }()
    private static let icons = ["face.smiling", "pawprint", "fork.knife", "car", "basketball", "lightbulb", "number", "flag"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(40), spacing: 0), count: 4), spacing: 0) {
                        if !recents.isEmpty { section("Recents", recents, id: -1) }
                        ForEach(Self.groups.indices, id: \.self) { index in
                            section(Self.groups[index].name, Self.groups[index].emoji, id: index)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: group) { value in withAnimation { reader.scrollTo("\(value)-0", anchor: .leading) } }
            }
            HStack(spacing: 0) {
                Button("ABC") { typing.showsEmoji = false }
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 48)
                ForEach(Self.icons.indices.prefix(Self.groups.count), id: \.self) { index in
                    Button { group = index } label: {
                        Image(systemName: Self.icons[index])
                            .foregroundStyle(group == index ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .accessibilityLabel(Self.groups[index].name)
                }
                Button { typing.keyTapped(KeySpec(action: .delete, label: "delete"), text: nil) } label: {
                    Image(systemName: "delete.left").frame(width: 48, height: 34)
                }
                .accessibilityLabel("Delete")
            }
            .buttonStyle(.plain)
            .frame(height: 38)
        }
    }

    @ViewBuilder
    private func section(_ name: String, _ emoji: [String], id: Int) -> some View {
        ForEach(Array(emoji.enumerated()), id: \.offset) { offset, item in
            Button { pick(item) } label: {
                Text(item).font(.system(size: 30)).frame(width: 44, height: 40)
            }
            .buttonStyle(.plain)
            .id("\(id)-\(offset)")
        }
    }

    private func pick(_ emoji: String) {
        typing.insertEmoji(emoji)
        recents = Array(([emoji] + recents.filter { $0 != emoji }).prefix(30))
        UserDefaults.standard.set(recents, forKey: Self.recentsKey)
    }
}
