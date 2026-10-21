# 2026-10-21: Update alert notes for every missed version

## Problem

Sparkle's update alert showed only the newest version's notes. A Mac user on
0.6.2 offered 0.6.4 never saw what changed in 0.6.3. Sparkle 2.10's
`SUUpdateAlert` reads only the selected appcast item, and nothing in Sparkle
merges notes across items.

## Decision

- The newest item's notes are cumulative HTML, one section per version, tagged
  `data-sparkle-version="<build>"`. Sparkle's release-notes web view adds the
  class `sparkle-installed-version` to the installed build's section, and the
  embedded CSS hides that section and everything after it.
  `scripts/sparkle-release-notes.py` writes the HTML, and
  `scripts/publish-github-release.sh` gives it to `generate_appcast` in place
  of the Markdown file.
- This fix is in the feed, not in app code, so copies that are already
  installed (every one uses Sparkle 2.10.0) get it at their next check.
  Rejected: the `standardUserDriverWillShowReleaseNotesText` delegate hook.
  It needs Sparkle's private Markdown formatter for the older notes, and it
  reaches only users who already run the new app.
- History comes from the live appcast: the sections in its items, or the
  Markdown notes of items from before this change. Up to 10 versions are
  listed, followed by an "Earlier releases" link. The link is hidden when the
  installed version is in the list.

## Verification

- I reran the publish steps for 0.6.4 against the v0.6.3 appcast:
  `generate_appcast` embedded the HTML, and the history kept 0.6.1 after its
  item was pruned. `verify-appcast.swift` passed.
- On the installed, notarized 0.6.3 (Mac mini), I set the `SUFeedURL` user
  default to a local feed and pressed Settings › About › Check for Updates:
  - The real 0.6.4 feed showed only the 0.6.4 notes.
  - A feed with two simulated releases (0.6.5 and 0.6.6, each built by
    chaining the script) showed 0.6.6, 0.6.5 and 0.6.4. 0.6.3, the older
    versions and the link were hidden, in both the screenshot and the
    accessibility tree.
- Afterwards I removed the default and relaunched the app.
