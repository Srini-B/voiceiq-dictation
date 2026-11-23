#!/usr/bin/env python3
"""Writes granola-export.zip and not-granola.zip, synthetic stand-ins for
Granola's account export (Settings > Profile > Generate CSV). Every name,
address and line in them is made up.

The real export is a ZIP of one or more UTF-8 CSV files with the columns
document_id, user_email, document_title, workspace_name, document_created,
summary, notes, transcript; see docs/GRANOLA_IMPORT.md.

Run from this folder: python3 make_granola_export.py
"""
import csv
import io
import zipfile

HEADER = ["document_id", "user_email", "document_title", "workspace_name",
          "document_created", "summary", "notes", "transcript"]

PLANNING_SUMMARY = """Quarterly planning for the Atlas launch.

### Launch scope
- Ship the beta to 50 design partners
  - Start with the three pilot teams
- Keep pricing out of v1

### Decisions
- Launch date is 14 March

### Action Items
- **Priya**: send the partner list by Friday
- [ ] Book the launch review
"""

ROWS_A = [
    ["0b7e6d2a-1c3f-4e5a-9b8c-7d6e5f4a3b21", "owner@example.test", "Atlas planning, Q1 ☕", "Example Team",
     "2026-10-24T14:34:40.866Z", PLANNING_SUMMARY, "remember the \"beta\" badge\n- ask about SSO",
     "Me: Shall we start with scope?\nThem: Yes, scope first.\nThe beta goes to fifty partners."],
    ["5f1a2b3c-4d5e-4f60-8a71-b2c3d4e5f607", "owner@example.test", "Hiring sync", "Example Team",
     "2026-09-02T09:00:00Z", "", "Candidate pipeline looks healthy", ""],
    ["9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d", "owner@example.test", "Bad date", "Example Team",
     "not a date", "### Notes\n- text", "", ""],
    ["1d2c3b4a-5f6e-4d7c-8b9a-0f1e2d3c4b5a", "owner@example.test", "Empty note", "Example Team",
     "2026-08-01T10:00:00Z", "", "", ""],
]

ROWS_B = [
    ["7c6b5a49-3827-4165-9f4e-3d2c1b0a9f8e", "owner@example.test", "Customer call, Northwind", "Side Project",
     "2026-11-20T16:15:00.000Z", "**Overview**\nThey want exports.\n\n**Next steps**\n1. Send the API docs",
     "", "Thanks for joining. We mostly use spreadsheets today."],
    # Also in the first file: the second copy is skipped.
    ["5f1a2b3c-4d5e-4f60-8a71-b2c3d4e5f607", "owner@example.test", "Hiring sync", "Example Team",
     "2026-09-02T09:00:00Z", "", "Candidate pipeline looks healthy", ""],
]


def csv_bytes(rows, bom=False, crlf=True):
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\r\n" if crlf else "\n", quoting=csv.QUOTE_MINIMAL)
    writer.writerow(HEADER)
    writer.writerows(rows)
    return (("\ufeff" if bom else "") + out.getvalue()).encode("utf-8")


def write(path, entries):
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in entries:
            info = zipfile.ZipInfo(name, date_time=(2026, 11, 23, 9, 0, 0))
            info.compress_type = zipfile.ZIP_STORED if name.endswith("/") else zipfile.ZIP_DEFLATED
            archive.writestr(info, data)


write("granola-export.zip", [
    ("granola-export/", b""),
    ("granola-export/notes-1.csv", csv_bytes(ROWS_A, bom=True)),
    ("granola-export/notes-2.csv", csv_bytes(ROWS_B, crlf=False)),
    ("__MACOSX/granola-export/._notes-1.csv", b"\x00\x05\x16\x07junk"),
    ("granola-export/.DS_Store", b"junk"),
])
write("not-granola.zip", [("readme.txt", b"no CSV here")])
