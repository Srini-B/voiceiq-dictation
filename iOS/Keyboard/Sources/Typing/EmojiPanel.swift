import SwiftUI

/// Emoji by category, recent ones first, scrolled sideways like the iOS
/// keyboard. The list is Unicode's, in CLDR order (`EmojiData`). Holding an
/// emoji that takes a skin tone offers the tones; the one picked becomes the
/// tone every emoji shows in.
struct EmojiPanel: View {
    @ObservedObject var typing: TypingController
    @State private var recents = EmojiData.recents
    @State private var group = 0
    @State private var tones: [String]?

    private static let icons = ["face.smiling", "pawprint", "fork.knife", "car", "basketball", "lightbulb", "number", "flag"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(40), spacing: 0), count: 4), spacing: 0) {
                        if !recents.isEmpty { section(recents, id: -1, tone: false) }
                        ForEach(EmojiData.groups.indices, id: \.self) { index in
                            section(EmojiData.groups[index].emoji, id: index, tone: true)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: group) { value in withAnimation { reader.scrollTo("\(value)-0", anchor: .leading) } }
            }
            .overlay(alignment: .top) {
                if let tones { tonePicker(tones) }
            }
            HStack(spacing: 0) {
                Button("ABC") { typing.showsEmoji = false }
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 48)
                Button { typing.startEmojiSearch() } label: {
                    Image(systemName: "magnifyingglass").frame(width: 40, height: 34).contentShape(Rectangle())
                }
                .accessibilityLabel("Search Emoji")
                ForEach(Self.icons.indices.prefix(EmojiData.groups.count), id: \.self) { index in
                    Button { group = index } label: {
                        Image(systemName: Self.icons[index])
                            .foregroundStyle(group == index ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .accessibilityLabel(EmojiData.groups[index].name)
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
    private func section(_ emoji: [String], id: Int, tone: Bool) -> some View {
        ForEach(Array(emoji.enumerated()), id: \.offset) { offset, item in
            let shown = tone ? EmojiData.toned(item) : item
            Text(shown)
                .font(.system(size: 30))
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
                // The hold is tried first, so a tap inside the scroll view
                // does not win the moment the finger lands.
                .gesture(LongPressGesture(minimumDuration: 0.35)
                    .onEnded { _ in
                        if let variants = EmojiData.skinTones(of: item) { tones = variants } else { pick(shown) }
                    }
                    .exclusively(before: TapGesture().onEnded { pick(shown) }))
                .accessibilityAddTraits(.isButton)
                .id("\(id)-\(offset)")
        }
    }

    private func tonePicker(_ variants: [String]) -> some View {
        HStack(spacing: 0) {
            ForEach(variants, id: \.self) { variant in
                Button {
                    EmojiData.noteSkinTone(of: variant)
                    pick(variant)
                } label: {
                    Text(variant).font(.system(size: 30)).frame(width: 46, height: 46).contentShape(Rectangle())
                }
            }
            Button { tones = nil } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 46)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(typing.theme.popup)).shadow(radius: 3, y: 1))
        .padding(.top, 6)
    }

    private func pick(_ emoji: String) {
        tones = nil
        typing.insertEmoji(emoji)
        recents = EmojiData.recents
    }
}
