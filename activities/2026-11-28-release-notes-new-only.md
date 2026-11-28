# 2026-11-28: Release notes carry only what's new

cyron's rule, relayed by the Space: from 0.7.19 on, release notes drop the Chrome-extension "Before you update" line, and no release repeats a notice from an earlier one. Each release's notes cover what's new in it, plus any "Before you update" item that release itself needs (0.7.19: the AssemblyAI key and the LLM Gateway balance).

- `release-notes/0.7.19.notice.md` loses the Chrome-extension line and the meetings-on-AssemblyAI line. The first bullet already says meetings use AssemblyAI, and the On device → cloud notice shipped in 0.7.18.
- Sparkle's update alert shows the notes of every version a user skipped, so someone updating from 0.7.17 still sees 0.7.18's notices.
- `docs/UPDATES.md` states the rule. The integrator's daily release check no longer gates on the Chrome line (old gate e).
