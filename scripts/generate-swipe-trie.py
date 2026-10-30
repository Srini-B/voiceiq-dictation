#!/usr/bin/env python3
"""Builds iOS/Keyboard/Resources/swipe/words.trie, the dictionary FUTO Swipe
decodes against, from AOSP's English word list (Apache 2.0).

FUTO's own loader parses the word list into ~220-byte nodes, about 98 MB:
more than a keyboard extension may use. This file is the same trie, memory-
mapped by MappedTrie.cpp, so its pages are clean and backed by the bundle.

Layout, little endian:
  header  "VQST", version u32 (1), node count u32, blob size u32
  nodes   per node: first child u32, word offset u32 (0xFFFFFFFF = not a
          word), child count u8, letter u8 (0-25; 255 for the root), depth u8,
          frequency u8 (AOSP's 0-255 log frequency)
          Breadth-first, so each node's children are contiguous and sorted.
  blob    the words as typed, NUL-terminated UTF-8
A node's letters are its word with everything but a-z dropped and lowercased,
so "don't" sits at d-o-n-t, as in FUTO's loader.
"""
import gzip, os, struct, urllib.request
from collections import deque

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "iOS/Keyboard/Resources/swipe/words.trie")
CACHE = os.path.expanduser("~/Library/Caches/voiceiq-keyboard-data")
# AOSP's en_US word list as FUTO Keyboard ships it, pinned.
SOURCE = ("https://raw.githubusercontent.com/futo-org/android-keyboard/"
          "31e720ddcc2df6259069b2ae7cf0f1defaf2cb74/dictionaries/en_US_wordlist.combined.gz")
LETTERS = "abcdefghijklmnopqrstuvwxyz"
NONE = 0xFFFFFFFF


def fetch():
    path = os.path.join(CACHE, "en_US_wordlist.combined.gz")
    if not os.path.exists(path):
        os.makedirs(CACHE, exist_ok=True)
        urllib.request.urlretrieve(SOURCE, path)
    return gzip.decompress(open(path, "rb").read()).decode("utf-8")


def parse(text):
    """Letters -> (frequency, spelling). The spelling is the most frequent
    form, preferring one whose letters are lowercase, so "us" is not "US"."""
    forms = {}
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("word="):
            continue
        fields = dict(part.split("=", 1) for part in line.split(",") if "=" in part)
        word, freq = fields["word"].replace("’", "'"), fields.get("f")
        if freq is None or not freq.isdigit():
            continue
        # Misspellings ("alot") and offensive words are never slid to.
        if fields.get("not_a_word") == "true" or fields.get("possibly_offensive") == "true":
            continue
        if any(c.isalpha() and c.lower() not in LETTERS for c in word):
            continue
        key = "".join(c for c in word.lower() if c in LETTERS)
        if key:
            forms.setdefault(key, []).append((int(freq), word))
    out = {}
    for key, entries in forms.items():
        best = max(f for f, _ in entries)
        lower = [e for e in entries if not any(c.isupper() for c in e[1])]
        out[key] = (best, max(lower or entries)[1])
    return out


def build(words):
    children = {"": set()}
    for key in words:
        for i in range(1, len(key) + 1):
            children.setdefault(key[:i], set())
            children[key[:i - 1]].add(key[i - 1])
    order, index = [], {}
    queue = deque([""])
    while queue:
        prefix = queue.popleft()
        index[prefix] = len(order)
        order.append(prefix)
        queue.extend(prefix + c for c in sorted(children[prefix]))
    blob = bytearray()
    records = []
    for prefix in order:
        kids = sorted(children[prefix])
        first = index[prefix + kids[0]] if kids else 0
        offset = NONE
        freq = 0
        if prefix in words:
            freq, spelling = words[prefix]
            offset = len(blob)
            blob += spelling.encode() + b"\0"
        letter = 255 if not prefix else LETTERS.index(prefix[-1])
        records.append(struct.pack("<IIBBBB", first, offset, len(kids), letter, min(len(prefix), 255), min(freq, 255)))
    return b"VQST" + struct.pack("<III", 1, len(order), len(blob)) + b"".join(records) + bytes(blob)


def main():
    words = parse(fetch())
    data = build(words)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, "wb").write(data)
    print(f"✓ {os.path.relpath(OUT, ROOT)}: {len(words)} words, {len(data)} bytes")


if __name__ == "__main__":
    main()
