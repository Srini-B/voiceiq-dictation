# Meeting folders

2026-11-23. Not released.

## Why

cyron asked for a way to categorize meetings by adding them to folders, like
tags. Read as: make, rename and delete folders in Meetings; put a meeting in
one or more; show one folder's meetings; show a meeting's folders; deleting a
folder keeps its meetings. Mac and iPhone behave the same, folders sync with
iCloud like meetings, and coding agents see them through `list_meetings` and
`get_meeting`.

## Decisions

- **Membership lives in `folder-ids.json`, not `meta.json`.** `MeetingEngine`
  keeps a meeting's meta in memory while it transcribes and saves it at each
  step, so a folder chosen then would be overwritten. A file of its own has
  one writer.
- **Membership travels in the meeting's CloudKit record.** `SyncedMeeting`
  gains an optional `folderIDs`, encoded only when present, so meetings in no
  folder keep their digest and nothing is re-sent on upgrade.
- **The folder list syncs through the iCloud key-value store**
  (`meetingFolders.v1`), merged per folder with deletion times like the
  dictionary. A new CloudKit record type would need a production schema
  deploy, and the list is small.
- **Deleting a folder leaves its id in meetings' files.** Removing it would
  re-send every meeting in the folder; the id is skipped instead.
- **Same-name folders become one** (the older), with the newer id recorded as
  an alias, so meetings filed in either stay filed. Found on the simulator:
  without it, devices that each made "Clients" showed it twice.
- **Shared SwiftUI.** The folder model, menus and dialogs are in
  `MeetingFolderViews.swift` in VoiceIQCore, used by both apps.
- **Importers** call `createFolder(named:)`, which returns an existing folder
  of that name, then `setFolderIDs(_:for:)`. The Granola import thread was
  given this API; Granola's export has no folders, so nothing maps yet.

## Verification

- `swift test --package-path VoiceIQCore`: 189 tests pass on Xcode 27, on a
  Mac satellite (the Mac mini was not used: this work could not start a
  runner thread). New: `MeetingFoldersTests` (name reuse, merge order,
  tombstones and aliases, delete keeps meetings, membership sync both ways, an
  unreadable list or membership file is never saved over or sent);
  `AgentAPITests.testMeetingsShowTheirFoldersAndFilterByOne`.
- Both app schemes build unsigned. Driven by hand with sample data on an
  unsigned Debug Mac build and the iPhone 17 Pro simulator: filter, file from
  the detail and from a row's menu, New Folder from a meeting, delete (the
  meetings stay and the filter returns to All).
- Not tried: two real devices syncing through iCloud, or a signed build.
