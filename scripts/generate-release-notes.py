#!/usr/bin/env python3
"""Writes release notes for the version in project.yml from the changes since
the previous version, with an OpenAI model reading the commits and the diff.

    OPENAI_API_KEY=... scripts/generate-release-notes.py [output-dir]
    scripts/generate-release-notes.py --base   # print the previous version and its commit

The previous release is the newest earlier version with a tag v<version>
(versions a branch went through before merging have none), otherwise the
commit that set MARKETING_VERSION to the previous version. Outputs, in
output-dir (default build/release-notes):

    github.md  every section, for the GitHub release
    mac.md     Mac and shared changes, for the Sparkle update alert
    ios.txt    iPhone and shared changes, for TestFlight "What to Test"

release-notes/<version>.notice.md, when present, holds bullets a person wrote
for something users must do themselves (such as removing a browser extension
by hand). They go first in all three outputs, word for word.

RELEASE_NOTES_MODEL overrides the model (default gpt-6-luna). See docs/UPDATES.md.
"""

import json
import os
import re
import subprocess
import sys
import urllib.request

MODEL = os.environ.get("RELEASE_NOTES_MODEL", "gpt-6-luna")
DIFF_LIMIT = 150_000
DIFF_PATHS = ["App", "iOS", "VoiceIQCore/Sources", "project.yml"]
VERSION_LINE = re.compile(r'^\s*MARKETING_VERSION:\s*"?([^"\s]+)"?', re.M)
BUILD_LINE = re.compile(r'^\s*CURRENT_PROJECT_VERSION:\s*"?([^"\s]+)"?', re.M)


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def version_at(commit):
    try:
        match = VERSION_LINE.search(git("show", f"{commit}:project.yml"))
    except subprocess.CalledProcessError:
        return None
    return match.group(1) if match else None


def build_at(commit):
    match = BUILD_LINE.search(git("show", f"{commit}:project.yml"))
    return match.group(1) if match else None


def tag_exists(tag):
    return subprocess.run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag}"], capture_output=True).returncode == 0


def previous_release(current):
    """(previous version, commit) or (None, None) when this is the first version."""
    commits = git("log", "--format=%H", "-G", "MARKETING_VERSION", "HEAD", "--", "project.yml").split()
    index = 0
    while index < len(commits) and version_at(commits[index]) == current:
        index += 1
    if index == len(commits):
        return None, None
    # The newest earlier version that was released (has a tag): versions a
    # branch went through before merging (only on TestFlight) are skipped,
    # so the notes cover everything since the last public release.
    for commit in commits[index:]:
        version = version_at(commit)
        if version and version != current and tag_exists(f"v{version}"):
            return version, git("rev-list", "-n", "1", f"v{version}").strip()
    previous = version_at(commits[index])
    # The oldest commit of the run that carried the previous version introduced it.
    while index + 1 < len(commits) and version_at(commits[index + 1]) == previous:
        index += 1
    return previous, commits[index]


def changes(base):
    log = git("log", "--no-merges", "--format=### %s%n%b", f"{base}..HEAD")
    stat = git("diff", "--stat", f"{base}..HEAD")
    diff = git("diff", f"{base}..HEAD", "--", *DIFF_PATHS)
    if len(diff) > DIFF_LIMIT:
        diff = diff[:DIFF_LIMIT] + "\n[diff truncated]"
    return f"## Commits\n{log}\n## Files changed\n{stat}\n## Diff\n{diff}"


INSTRUCTIONS = """You write release notes for VoiceiQ, a voice dictation app with a Mac app \
and an iPhone app (with a keyboard). You get the commits and the code diff since the \
previous release. Write notes for the people who use the apps, not for developers.

- One short sentence per item, in plain words, saying what changed for the user.
- Put each item in exactly one list: "both" when it affects the Mac and iPhone apps, \
"mac" for the Mac app only, "iphone" for the iPhone app or its keyboard only.
- Leave out changes users cannot notice: refactors, tests, docs, build and release \
tooling, CI, license headers.
- Merge related commits into one item. Most important first. At most 8 items per list.
- No file names, class names, commit hashes, or internal jargon."""

SCHEMA = {
    "type": "object",
    "properties": {name: {"type": "array", "items": {"type": "string"}} for name in ("both", "mac", "iphone")},
    "required": ["both", "mac", "iphone"],
    "additionalProperties": False,
}


def ask_model(version, previous, material):
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        sys.exit("error: OPENAI_API_KEY is not set")
    body = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": INSTRUCTIONS},
            {"role": "user", "content": f"Release {version}, changes since {previous or 'the first commit'}:\n\n{material}"},
        ],
        "response_format": {"type": "json_schema", "json_schema": {"name": "release_notes", "strict": True, "schema": SCHEMA}},
    }
    request = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=300) as response:
        reply = json.load(response)
    return json.loads(reply["choices"][0]["message"]["content"])


def bullets(items):
    return "".join(f"- {item}\n" for item in items)


def main():
    current = version_at("HEAD")
    previous, base = previous_release(current)
    if sys.argv[1:] == ["--base"]:
        print(previous or "", base or "", build_at(base) if base else "")
        return
    out = sys.argv[1] if len(sys.argv) > 1 else "build/release-notes"
    os.makedirs(out, exist_ok=True)
    base = base or git("rev-list", "--max-parents=0", "HEAD").split()[0]
    print(f"Release notes for {current}: changes since {previous or 'the first commit'} ({base[:10]})", file=sys.stderr)
    notes = ask_model(current, previous, changes(base))
    if not any(notes.values()):
        notes["both"] = ["Fixes and improvements."]

    notice_path = os.path.join("release-notes", f"{current}.notice.md")
    notice = open(notice_path).read().strip() + "\n" if os.path.exists(notice_path) else ""
    sections = [("Mac and iPhone", notes["both"]), ("Mac", notes["mac"]), ("iPhone", notes["iphone"])]
    github = (f"## Before you update\n\n{notice}\n" if notice else "") + "".join(f"## {title}\n\n{bullets(items)}\n" for title, items in sections if items)
    repo = os.environ.get("GITHUB_REPOSITORY")
    if repo and previous:
        github += f"Full changes: https://github.com/{repo}/compare/{base[:12]}...v{current}\n"
    with open(os.path.join(out, "github.md"), "w") as f:
        f.write(github)
    with open(os.path.join(out, "mac.md"), "w") as f:
        f.write(notice + (bullets(notes["both"] + notes["mac"]) or "- Fixes and improvements.\n"))
    with open(os.path.join(out, "ios.txt"), "w") as f:
        f.write((notice + (bullets(notes["both"] + notes["iphone"]) or "- Fixes and improvements.\n"))[:3900])
    print(github)


if __name__ == "__main__":
    main()
