"""Rebuilds the production cleanup prompt prefix from the Swift sources.

Mirrors PromptV1.cleanupPrompt(raw:) with no vocabulary, spellings, custom
rules, spelling variant, images, field, place, normalized candidate or
reminder: rules, writing rules, examples, layout reminder, then "RAW: ...".
"""
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
prompt_src = (repo / "VoiceIQCore/Sources/FormattingPipeline/PromptV1.swift").read_text()
rules_src = (repo / "VoiceIQCore/Sources/FormattingPipeline/DefaultWritingRules.swift").read_text()


def unescape(s: str) -> str:
    assert "\\(" not in s, "interpolation inside a static prompt block"
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'"}.get(n, "\\" + n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def multiline(src: str, decl: str) -> str:
    start = src.index(decl)
    body_start = src.index('"""\n', start) + 4
    end = src.index('"""', body_start)
    block = src[body_start:end]
    lines = block.split("\n")
    indent = lines[-1]  # whitespace before the closing delimiter
    assert indent.strip() == ""
    content = [l[len(indent):] if l.startswith(indent) else l.lstrip() for l in lines[:-1]]
    joined = "\n".join(content)
    joined = re.sub(r"\\\n", "", joined)  # Swift line continuation
    return unescape(joined)


def single(src: str, decl: str) -> str:
    m = re.search(re.escape(decl) + r' = "((?:[^"\\]|\\.)*)"', src)
    return unescape(m.group(1))


rules = multiline(prompt_src, "static let rules = ")
examples = multiline(prompt_src, "static let examples = ")
layout = single(prompt_src, "static let layoutReminder")
default_rules = multiline(rules_src, "public static let text = ")

writing = f"Writing rules from the user (follow these; they refine the rules above):\n<rules>\n{default_rules}\n</rules>"
prefix = "\n\n".join([rules, writing, examples, layout]) + "\n\n"
Path(sys.argv[2]).write_text(prefix)
print(f"prefix chars={len(prefix)} words={len(prefix.split())}")
# The same prompt without the DefaultWritingRules block, which restates most
# of PromptV1.rules: a shorter variant for small models.
compact = "\n\n".join([rules, examples, layout]) + "\n\n"
Path(sys.argv[2]).with_name("prompt_compact.txt").write_text(compact)
print(f"compact chars={len(compact)} words={len(compact.split())}")
