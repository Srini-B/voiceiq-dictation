# Import meetings from Granola

2026-11-23. Not released.

## Why

cyron wants people moving from Granola to bring every meeting with them:
pick the ZIP that Granola's account export produces, and get each meeting
as a VoiceiQ meeting, without audio.

## What the export is

Granola's export (Settings › Profile › Generate CSV) is emailed as a ZIP of
UTF-8 CSV files, one row per note. The columns are `document_id`,
`user_email`, `document_title`, `workspace_name`, `document_created`,
`summary`, `notes` and `transcript`. Granola's docs do not list them. Two
importers that read real exports do: Muesli (verified against an October
2026 export) and Wispr Flow. A July 2026 export test by hirekai.ai found full
transcripts without speaker labels and an empty `notes` column when nothing
was typed. The export has no attendees, folders, duration or audio. No real
export was available here. The format is from those sources, and the
importer accepts any column order and extra columns.

## What changed

- Settings › Privacy & Storage (Mac) and Settings › Privacy (iPhone, iPad)
  have **Import meetings › Import from Granola…**: a file picker, a preview
  (counts, date range, titles, skipped rows with reasons), the import with
  progress, then a report.
- Each note becomes a finished meeting whose id is Granola's `document_id`,
  so a repeat import, or the same note arriving through iCloud, is never
  doubled. Meetings deleted in VoiceiQ on this device are not brought back
  (`deleted-imports.json`).
- `MeetingMeta.importedFrom` ("Granola") marks imported meetings. Exports
  and the agent Markdown say "Imported from Granola" instead of a length.
- The ZIP is read by a small reader on the Compression framework
  (`ZipArchive`), since Foundation cannot unzip on iOS. No dependency added.
- Docs: `docs/GRANOLA_IMPORT.md`.

## Verification

- `swift test --filter "GranolaImportTests|MeetingSyncTests|AgentAPITests"`
  on a macOS 27 satellite with Xcode 27.3: 19 tests, 0 failures. The tests
  use a synthetic export written by
  `Tests/VoiceIQCoreTests/Fixtures/make_granola_export.py`.
- Unsigned Debug builds of the VoiceIQ and VoiceIQiOS schemes succeeded. The
  iOS Simulator build linked only for arm64 on the satellite; its x86_64
  link fails in the vendored llama library, unrelated to this change.
- On the satellite's Debug Mac app: picked the synthetic ZIP in the real file
  panel, saw the preview, imported, and opened the meetings in Meetings with
  notes, action items, decisions and transcript.

## Not done

- The Meetings list shows "0s" for an imported meeting, and the agent
  listing has no `importedFrom` field. Both live in files the meeting-folders
  work owns (`MeetingsView.swift` on both platforms, `AgentLibrary.swift`),
  so they follow once that lands.
- Not tried against a real Granola export, nor on an iPhone.
- Not tried in a signed, notarized build, as AGENTS.md asks for Mac app
  testing. That needs the release flow and its signing credentials. The
  Debug build has no iCloud entitlement, so iCloud sync of imported
  meetings was not exercised end to end; `MeetingSyncTests` and
  `GranolaImportTests` cover that they queue for upload.
- A meeting deleted on another device comes back if this device imports the
  same export again: only deletes made here are remembered.
