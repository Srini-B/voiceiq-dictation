#!/usr/bin/env python3
"""Writes the release notes for the Mac app's update alert: this version's
notes and those of the versions before it, newest first, as the HTML that
generate_appcast embeds in the new appcast item.

    scripts/sparkle-release-notes.py <appcast.xml> <build> <version> <notes.md> <releases-url>

Sparkle shows only the newest item's notes, however old the installed app is.
Each version's notes are a section tagged with its build number. Sparkle adds
the class sparkle-installed-version to the installed build's section, and the
CSS hides that section and everything after it, so each user sees the versions
they are missing. The earlier sections come from the current appcast (missing
on the first release): the sections in its items, or the Markdown notes of
items published before this script. See docs/UPDATES.md.
"""

import html
import os
import re
import sys
import xml.etree.ElementTree as ET

MAX_VERSIONS = 10
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
SECTION = re.compile(r'<section data-sparkle-version="(\d+)">.*?</section>', re.S)
STYLE = "<style>.sparkle-installed-version, .sparkle-installed-version ~ * { display: none; }</style>"


def notes_html(markdown):
    """The bullets and paragraphs that generate-release-notes.py writes."""
    out, in_list = [], False
    for line in markdown.splitlines():
        line = line.strip()
        bullet = line[:2] in ("- ", "* ")
        if in_list and not bullet:
            out.append("</ul>")
            in_list = False
        if bullet:
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{html.escape(line[2:].strip(), quote=False)}</li>")
        elif line:
            out.append(f"<p>{html.escape(line, quote=False)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def section(build, version, markdown):
    return f'<section data-sparkle-version="{build}">\n<h3>VoiceiQ {html.escape(version, quote=False)}</h3>\n{notes_html(markdown)}\n</section>'


def earlier_sections(appcast):
    """{build: section} for every version the appcast has notes for."""
    sections = {}
    if not os.path.exists(appcast):
        return sections
    for item in ET.parse(appcast).getroot().iter("item"):
        notes = item.findtext("description") or ""
        for match in SECTION.finditer(notes):
            sections.setdefault(int(match[1]), match[0])
        build = item.findtext(f"{SPARKLE}version")
        if build and int(build) not in sections and notes.strip():
            version = item.findtext(f"{SPARKLE}shortVersionString") or build
            sections[int(build)] = section(build, version, notes)
    return sections


def main():
    if len(sys.argv) != 6:
        sys.exit("usage: sparkle-release-notes.py <appcast.xml> <build> <version> <notes.md> <releases-url>")
    appcast, build, version, notes_path, releases_url = sys.argv[1:]
    sections = {b: s for b, s in earlier_sections(appcast).items() if b < int(build)}
    with open(notes_path) as f:
        sections[int(build)] = section(build, version, f.read())
    print(STYLE)
    for b in sorted(sections, reverse=True)[:MAX_VERSIONS]:
        print(sections[b])
    # Hidden like the older sections, so only users further behind than
    # MAX_VERSIONS see it.
    print(f'<p><a href="{html.escape(releases_url)}">Earlier releases</a></p>')


if __name__ == "__main__":
    main()
