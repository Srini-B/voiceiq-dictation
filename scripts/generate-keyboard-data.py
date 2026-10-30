#!/usr/bin/env python3
"""Build the iPhone keyboard's word list and emoji list.

    scripts/generate-keyboard-data.py

Writes iOS/Keyboard/Resources/lexicon.bin and iOS/Keyboard/Resources/emoji.txt
from pinned upstream files (THIRD_PARTY_NOTICES.md, "Keyboard data"). The
binary layout is read by iOS/Keyboard/Sources/Typing/Lexicon.swift; change both
together.

lexicon.bin, little-endian:
  header   40 bytes: "VQLX", version, word count, bigram count, blob size,
           then float32 ln(min count), ln(max count), ln(total count),
           ln(min pair count), ln(max pair count)
  words    8 bytes each, sorted by key: blob offset u32, key length u8,
           display length u8 (0 = same as key), frequency u8, flags u8
  pairs    8 bytes each, sorted by first word then score: first u32, second u32
  scores   1 byte per pair
  blob     keys and display forms, UTF-8
A key is the lowercase word without apostrophes, so "dont" finds "don't".
Frequencies are ln(count) scaled to 0...255 between the header's bounds.
"""
import hashlib, math, os, re, struct, sys, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "iOS/Keyboard/Resources")
CACHE = os.path.expanduser("~/Library/Caches/voiceiq-keyboard-data")

SOURCES = {
    "words": "https://raw.githubusercontent.com/wolfgarbe/SymSpell/91fe939e9c1259813ee817e95239629c5badf8ec/SymSpell/frequency_dictionary_en_82_765.txt",
    "pairs": "https://raw.githubusercontent.com/wolfgarbe/SymSpell/91fe939e9c1259813ee817e95239629c5badf8ec/SymSpell/frequency_bigramdictionary_en_243_342.txt",
    "hunspell": "https://raw.githubusercontent.com/wooorm/dictionaries/8cfea406b505e4d7df52d5a19bce525df98c54ab/dictionaries/en/index.dic",
    "blocked": "https://raw.githubusercontent.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words/5faf2ba42d7b1c0977169ec3611df25a3c08eb13/en",
    # Emoji 15.0 is the newest set iOS 17.0, the deployment target, draws.
    "emoji": "https://unicode.org/Public/emoji/15.0/emoji-test.txt",
}

# Contractions are in the word list at a placeholder count. These are typed
# far more often than that; counts are rough Google Books magnitudes.
CONTRACTIONS = {
    "don't": 3e8, "i'm": 2.5e8, "it's": 3e8, "can't": 2e8, "didn't": 2e8, "that's": 2e8,
    "i'll": 1.5e8, "won't": 1.2e8, "doesn't": 1.2e8, "isn't": 1e8, "i've": 1e8, "you're": 1e8,
    "i'd": 8e7, "there's": 8e7, "let's": 8e7, "he's": 6e7, "she's": 5e7, "wasn't": 8e7,
    "couldn't": 8e7, "wouldn't": 8e7, "they're": 6e7, "we're": 6e7, "what's": 6e7,
    "haven't": 5e7, "aren't": 4e7, "you'll": 4e7, "shouldn't": 3e7, "we'll": 3e7,
    "you've": 3e7, "hadn't": 3e7, "weren't": 3e7, "they'll": 2e7, "we've": 2e7,
    "they've": 2e7, "you'd": 2e7, "he'd": 2e7, "she'd": 1.5e7, "they'd": 1.5e7,
    "we'd": 1e7, "who's": 1e7, "here's": 1e7, "where's": 8e6, "hasn't": 1e7, "ain't": 1e7,
    "y'all": 5e6, "how's": 4e6, "mustn't": 3e6, "o'clock": 1e7, "ma'am": 5e6,
    "should've": 4e6, "would've": 4e6, "could've": 4e6, "might've": 2e6, "must've": 2e6,
}
# Typed without the apostrophe these are not words (or are rare ones), so the
# keyboard corrects them the way the iOS keyboard does.
PREFER_CONTRACTION = {
    "dont", "im", "cant", "didnt", "thats", "wont", "doesnt", "isnt", "ive", "youre",
    "theres", "wasnt", "couldnt", "wouldnt", "theyre", "whats", "havent", "arent",
    "youll", "shouldnt", "youve", "hadnt", "werent", "theyll", "weve", "theyve",
    "youd", "whos", "heres", "wheres", "hasnt", "aint", "yall", "hows", "mustnt",
    "shouldve", "wouldve", "couldve", "mightve", "mustve",
}
# Common in messages, missing from a list built from books.
CHAT_WORDS = {"ok": 1e8, "lol": 2e7, "btw": 5e6, "omg": 5e6, "idk": 3e6, "pls": 3e6, "thx": 2e6,
              "brb": 1e6, "imo": 1e6, "tbh": 1e6, "asap": 5e6, "wanna": 1e7, "gotta": 1e7, "yeah": 3e7,
              "okay": 3e7, "hey": 3e7, "emoji": 5e6, "selfie": 1e6, "app": 3e7, "apps": 1e7}
FLAG_NO_SUGGEST, FLAG_PREFERRED = 1, 2


def fetch(name):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name)
    if not os.path.exists(path):
        urllib.request.urlretrieve(SOURCES[name], path)
    data = open(path, "rb").read()
    print(f"  {name}: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()[:16]}")
    return data.decode("utf-8-sig")


def key_of(word):
    return word.lower().replace("'", "")


def cased_forms(hunspell):
    """Lowercase word -> its dictionary spelling, for words never written lowercase."""
    entries = [line.split("/")[0] for line in hunspell.splitlines()[1:] if line]
    lower = {w for w in entries if w == w.lower()}
    cased = {}
    for word in entries:
        if word == word.lower() or word.lower() in lower:
            continue
        cased.setdefault(word.lower(), word)
    return cased, {w for w in entries if "'" in w}


def main():
    print("▸ Sources")
    words_raw, pairs_raw = fetch("words"), fetch("pairs")
    hunspell, blocked_raw, emoji_raw = fetch("hunspell"), fetch("blocked"), fetch("emoji")
    cased, apostrophe_words = cased_forms(hunspell)
    blocked = {line.strip().lower() for line in blocked_raw.splitlines() if line.strip() and " " not in line.strip()}

    counts = {}
    for line in words_raw.splitlines():
        m = re.fullmatch(r"([a-z']+) (\d+)", line.strip())
        if not m:
            continue
        word = m.group(1)
        if "'" in word and word not in {w.lower() for w in apostrophe_words} | set(CONTRACTIONS):
            continue
        counts[word] = max(counts.get(word, 0), int(m.group(2)))
    for word, count in list(CONTRACTIONS.items()) + list(CHAT_WORDS.items()):
        counts[word] = max(counts.get(word, 0), int(count))

    entries = []
    for word, count in counts.items():
        display = word if word in CHAT_WORDS else cased.get(word, word)
        if word == "i" or word.startswith("i'"):
            display = "I" + word[1:]
        flags = 0
        if word in blocked or (len(word) == 1 and word not in ("a", "i")):
            flags |= FLAG_NO_SUGGEST
        if "'" in word and key_of(word) in PREFER_CONTRACTION:
            flags |= FLAG_PREFERRED
        entries.append((key_of(word).encode(), display.encode(), count, flags))
    entries.sort(key=lambda e: (e[0], -e[2]))
    index = {}
    for i, (key, display, _, _) in enumerate(entries):
        index.setdefault(display.decode().lower(), i)

    ln_counts = [math.log(e[2]) for e in entries]
    ln_min, ln_max = min(ln_counts), max(ln_counts)
    ln_total = math.log(sum(e[2] for e in entries))

    pairs = []
    for line in pairs_raw.splitlines():
        m = re.fullmatch(r"([a-z']+) ([a-z']+) (\d+)", line.strip())
        if m and m.group(1) in index and m.group(2) in index:
            pairs.append((index[m.group(1)], index[m.group(2)], int(m.group(3))))
    pairs.sort(key=lambda p: (p[0], -p[2]))
    pair_ln = [math.log(p[2]) for p in pairs]
    pmin, pmax = min(pair_ln), max(pair_ln)

    def q(value, lo, hi):
        return max(0, min(255, round((value - lo) / (hi - lo) * 255)))

    blob, records = bytearray(), bytearray()
    for (key, display, count, flags), ln in zip(entries, ln_counts):
        same = display == key
        records += struct.pack("<IBBBB", len(blob), len(key), 0 if same else len(display), q(ln, ln_min, ln_max), flags)
        blob += key + (b"" if same else display)
    header = b"VQLX" + struct.pack("<IIII5f", 1, len(entries), len(pairs), len(blob), ln_min, ln_max, ln_total, pmin, pmax)
    assert len(header) == 40
    body = bytearray(header) + records
    for a, b, _ in pairs:
        body += struct.pack("<II", a, b)
    body += bytes(q(ln, pmin, pmax) for ln in pair_ln)
    body += blob

    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "lexicon.bin"), "wb") as f:
        f.write(body)
    print(f"✓ lexicon.bin: {len(entries)} words, {len(pairs)} pairs, {len(body)} bytes")

    groups, group = [], None
    for line in emoji_raw.splitlines():
        if line.startswith("# group: "):
            name = line[9:].strip()
            group = None if name == "Component" else [name, []]
            if group:
                groups.append(group)
            continue
        m = re.match(r"([0-9A-F ]+);\s*fully-qualified\s*#\s*(\S+)", line)
        if not m or group is None:
            continue
        codes = m.group(1).split()
        if any(c in ("1F3FB", "1F3FC", "1F3FD", "1F3FE", "1F3FF") for c in codes):
            continue
        group[1].append("".join(chr(int(c, 16)) for c in codes))
    if groups and groups[0][0] == "Smileys & Emotion" and groups[1][0] == "People & Body":
        groups[0][1] += groups.pop(1)[1]
        groups[0][0] = "Smileys & People"
    with open(os.path.join(OUT, "emoji.txt"), "w") as f:
        for name, items in groups:
            f.write(name + "\t" + " ".join(items) + "\n")
    print(f"✓ emoji.txt: {sum(len(g[1]) for g in groups)} emoji in {len(groups)} groups")


if __name__ == "__main__":
    sys.exit(main())
