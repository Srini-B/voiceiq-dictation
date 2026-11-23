# Importing meetings from Granola

VoiceiQ imports every meeting in a Granola account from Granola's own
account export. The import needs no Granola login and no audio.

## Using it

1. In Granola, open **Settings › Profile** and click **Generate CSV**. Choose
   the workspaces to include. Granola emails a download link within a few
   hours; it is valid for 24 hours, and Granola allows one export a day.
2. Download the ZIP from the email.
3. In VoiceiQ, open **Settings › Privacy & Storage** on the Mac, or
   **Settings › Privacy** on the iPhone and iPad, and click **Import from
   Granola…** under **Import meetings**.
4. Choose the ZIP. A single CSV taken out of the ZIP also works.
5. Check the preview, then click **Import N meetings**.

The preview shows how many meetings the export holds, how many are new, their
date range and titles, how many are already in VoiceiQ, and every row that
will be skipped, with the reason. After the import, the same section reports
what was imported, left alone and skipped.

## What Granola's export contains

Granola documents the export at
<https://docs.granola.ai/help-center/sharing/exporting-notes>. It holds only
notes the user owns that have a summary; deleted notes and notes without a
summary are left out. The file layout below is not in Granola's docs. It
comes from two importers that read real exports: Muesli's October 2026
import notes (<https://github.com/Muesli-HQ/muesli/blob/main/docs/plans/granola-csv-import.md>)
and Wispr Flow's import guide.

The ZIP holds one or more UTF-8 CSV files with the same header row. Fields
use RFC 4180 quoting, so summaries and transcripts span lines.

| Column | Contents | In VoiceiQ |
| --- | --- | --- |
| `document_id` | The note's UUID | The meeting's id |
| `user_email` | The account owner | Not used (not an attendee) |
| `document_title` | Title | Title ("Untitled meeting" when empty) |
| `workspace_name` | Granola workspace | Not used |
| `document_created` | ISO 8601 creation time, UTC | Start date and time |
| `summary` | Granola's AI notes, Markdown | Summary, sections, decisions, action items |
| `notes` | What the user typed | Notes |
| `transcript` | Plain text, usually without speaker labels | Transcript |

The export has no audio, duration, end time, attendees, folders, or speaker
timestamps, so imported meetings have none. Granola has no other bulk export.

## How a row becomes a meeting

- **Identity.** The meeting's id is Granola's `document_id`, so the same note
  is the same meeting on every import and every device. A `document_id` that
  is not a UUID is hashed into one.
- **Summary.** Text before the first heading becomes the summary. With none,
  the summary reads "Imported from Granola." Each `#` heading, or a line that
  is all bold, starts a section of bullet items; a nested bullet becomes an
  indented `◦` line of the item above it. A section titled like action items, next steps, to-dos or
  follow-ups becomes action items; one titled like decisions becomes
  decisions. Bold markers and checkboxes are removed.
- **Typed notes.** Each line becomes an item under Notes.
- **Transcript.** Lines labelled `Me:` or `You:` are the note owner. Lines
  labelled `Them:` or `Speaker X:` are Speaker 1, 2 and so on, which can be
  named in Assign speakers. Unlabelled lines continue the turn before, or
  form paragraphs under the speaker "Transcript".
- **Meeting.** Status done, `importedFrom` "Granola", duration 0, no end time.
  Exports and the coding-agent Markdown show "Imported from Granola" where a
  recorded meeting shows its length.

Imported meetings are ordinary meetings. They list in Meetings, sync to the
user's other devices through iCloud, can be chatted with, and are readable by
coding agents through `list_meetings` and `get_meeting`. Redo notes writes new
notes from the transcript, replacing Granola's.

## Duplicates and skipped rows

- A meeting already in VoiceiQ is left as it is, including any edits made
  since. Importing the same export twice changes nothing.
- A meeting deleted in VoiceiQ on this device is not brought back; the
  ids of deleted imports are kept in `deleted-imports.json` beside the
  meeting folders. One deleted on another device is.
- A row that appears twice in the export is imported once.
- Rows are skipped, with the reason shown, when their date cannot be read,
  they have no summary, notes or transcript, or they have the wrong number of
  columns. A CSV in the ZIP with other columns is skipped as a whole.
- The whole file is refused, with nothing imported, when it is not a ZIP or
  CSV, holds no Granola CSV, is damaged (a CRC check fails), is
  password-protected or ZIP64, or is over 512 MB.

## Code

- `VoiceIQCore/Sources/MeetingEngine/GranolaImport.swift` reads the export,
  maps rows to meetings, plans the import and runs it.
- `VoiceIQCore/Sources/MeetingEngine/ZipArchive.swift` unzips stored and
  deflated entries with Apple's Compression framework, on macOS and iOS.
- `VoiceIQCore/Sources/MeetingEngine/GranolaImportSection.swift` is the
  Settings section both apps show.
- `VoiceIQCore/Tests/VoiceIQCoreTests/GranolaImportTests.swift` runs against a
  synthetic export written by `Fixtures/make_granola_export.py`. No real
  export is committed.
