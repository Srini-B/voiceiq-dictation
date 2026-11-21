#!/usr/bin/env python3
"""Build the iPhone keyboard's emoji lists for VoiceiQ's emoji panel.

    scripts/generate-keyboard-data.py

Writes iOS/Keyboard/Resources/emoji.txt and emoji-words.txt from pinned
upstream files (THIRD_PARTY_NOTICES.md, "Keyboard data"). Words, predictions
and slide to type come from Hex's typing model (iOS/Keyboard/Hex).
"""
import json, hashlib, os, re, sys, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "iOS/Keyboard/Resources")
CACHE = os.path.expanduser("~/Library/Caches/voiceiq-keyboard-data")

SOURCES = {
    # Emoji 17.0, the newest set any iOS draws (iOS 26.4). Newer emoji carry
    # their version so the keyboard hides them where iOS can't draw them.
    "emoji": "https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt",
    # GitHub's gemoji names, aliases and tags (MIT), as FUTO Keyboard ships it.
    "gemoji": "https://raw.githubusercontent.com/futo-org/android-keyboard/31e720ddcc2df6259069b2ae7cf0f1defaf2cb74/java/res/raw/gemoji.json",
}
TONES = ["\U0001F3FB", "\U0001F3FC", "\U0001F3FD", "\U0001F3FE", "\U0001F3FF"]
# Emoji newer than 15.0 are written with their version, "🫩@16.0", so
# EmojiData.drawable can hide the ones the running iOS cannot draw.
DRAWN_EVERYWHERE = 15.0


def fetch(name):
    os.makedirs(CACHE, exist_ok=True)
    # Keyed by URL too, so moving a pin never reuses the old file.
    path = os.path.join(CACHE, name + "-" + hashlib.sha256(SOURCES[name].encode()).hexdigest()[:12])
    if not os.path.exists(path):
        urllib.request.urlretrieve(SOURCES[name], path)
    data = open(path, "rb").read()
    print(f"  {name}: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()[:16]}")
    return data.decode("utf-8-sig")


def main():
    print("▸ Sources")
    emoji_raw = fetch("emoji")

    groups, group, versions = [], None, {}
    for line in emoji_raw.splitlines():
        if line.startswith("# group: "):
            name = line[9:].strip()
            group = None if name == "Component" else [name, []]
            if group:
                groups.append(group)
            continue
        m = re.match(r"([0-9A-F ]+);\s*fully-qualified\s*#\s*\S+\s+E(\d+\.\d+)", line)
        if not m:
            continue
        codes = m.group(1).split()
        emoji = "".join(chr(int(c, 16)) for c in codes)
        versions[emoji] = m.group(2)
        if group is None or any(c in ("1F3FB", "1F3FC", "1F3FD", "1F3FE", "1F3FF") for c in codes):
            continue
        group[1].append(emoji)
    if groups and groups[0][0] == "Smileys & Emotion" and groups[1][0] == "People & Body":
        groups[0][1] += groups.pop(1)[1]
        groups[0][0] = "Smileys & People"

    def tagged(emoji):
        return emoji + "@" + versions[emoji] if float(versions[emoji]) > DRAWN_EVERYWHERE else emoji

    with open(os.path.join(OUT, "emoji.txt"), "w") as f:
        for name, items in groups:
            f.write(name + "\t" + " ".join(map(tagged, items)) + "\n")
    print(f"✓ emoji.txt: {sum(len(g[1]) for g in groups)} emoji in {len(groups)} groups")
    write_emoji_words(fetch("gemoji"), tagged, versions, {e for _, items in groups for e in items})


def write_emoji_words(gemoji_raw, tagged, qualified, shown):
    """emoji-words.txt: per emoji, its five skin tones (if it takes them) and
    the words search matches. Emoji are tagged with their version like emoji.txt."""
    entries = [e for e in json.loads(gemoji_raw) if e["emoji"] in shown]
    people = {e["emoji"].replace("\uFE0F", "") for e in entries if e["category"] == "People & Body"}

    def toned(emoji, tone):
        parts = emoji.split("\u200D")
        every = "\u200D".join(p.replace("\uFE0F", "") + tone if p.replace("\uFE0F", "") in people else p for p in parts)
        first = "\u200D".join([parts[0].replace("\uFE0F", "") + tone] + parts[1:])
        return next((v for v in (every, first) if v in qualified), None)

    lines = []
    for e in entries:
        emoji = e["emoji"]
        tones = [toned(emoji, t) for t in TONES] if e.get("skin_tones") else []
        if None in tones:
            tones = []
        names = [e["description"]] + e["aliases"] + e["tags"]
        words = sorted({w for n in names for w in re.split(r"[^a-z0-9]+", n.lower()) if w})
        lines.append((float(qualified[emoji]) > DRAWN_EVERYWHERE,
                      tagged(emoji) + "\t" + " ".join(map(tagged, tones)) + "\t" + " ".join(words)))
    # Search shows matches in file order and the bar takes the first eight, so
    # emoji newer than every iOS draws go last: "right" still finds ➡️ before
    # the people facing right.
    lines = [line for _, line in sorted(lines, key=lambda l: l[0])]
    with open(os.path.join(OUT, "emoji-words.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"✓ emoji-words.txt: {len(lines)} emoji")

if __name__ == "__main__":
    sys.exit(main())
