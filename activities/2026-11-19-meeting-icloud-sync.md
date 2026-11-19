# Meeting sync through iCloud (2026-11-19)

**Why.** The owner asked for meeting notes to sync through iCloud the way
dictations and custom rules do, and for chat on meetings on iPhone like the
Mac. Standing rule: every platform gets the same features where it can.
The iPhone already had chat on notes (since 0.6.26), but only for notes
recorded on it. Mac meetings never reached the iPhone, so the missing piece
was the sync.

**Decisions.**
- `MeetingSync` copies `HistorySync`: `CKSyncEngine`, the same container
  and private database, its own `Meetings` zone and `Meeting` record type.
  The record has one field, `payload` (Bytes): the meeting's meta, notes,
  transcript and chat as LZFSE-compressed JSON. A single field keeps the
  Production schema step small, and compression keeps meetings several
  hours long under the 1 MB record limit.
- Always on, with no setting, like History and the dictionary. The first
  version had an opt-in toggle on each device, off by default; the owner
  asked to remove it and keep sync on in both apps.
- Chat syncs with the meeting: questions asked on either device appear on
  both.
- Audio is not synced. It can reach hundreds of MB per meeting in the
  user's iCloud storage. On the other device, Play, Download and Redo
  transcript are unavailable, and everything else works.
- Unlike History, a meeting can be edited on both devices. Change
  detection is a content digest kept in `cloud.json`, with the record's
  system fields. The device that sends last keeps its notes and names, and
  questions from both devices are merged by id.
- Review fixes: deletes are sent for any finished meeting, because its
  first upload may be in flight. Deleted ids are kept in
  `.sync/deletes.json` until iCloud confirms them, so a delete made
  before the engine started or saved its state still reaches iCloud. Fetched copies of those meetings
  are ignored. Cloud changes, and the read of what goes up, run on the
  main actor, where every local meeting edit happens. A delete from
  another device wins over an edit here that has not gone up yet.
  A meeting that could not be written here (a full disk), new or half
  updated, waits in `.sync/retry.json`: it is not sent, and it is fetched
  again by id and taken whole.

**Verification.**
- Test Mac at 25282a5: `scripts/test.sh` 187 tests, 0 failures (4 new
  `MeetingSyncTests`). `scripts/build.sh` and `scripts/build-ios.sh` both
  exit 0. CI is green.
- iOS 27 Simulator, Debug: Settings › Privacy shows "Sync notes with iCloud"
  (off) and a "Notes: Not synced" row. A seeded finished meeting with no
  audio opens with its notes and the "Ask about this note" field.
- Not verified: a real round trip between two devices. It needs the
  Production schema (below) and a signed Mac build plus an iPhone build on
  the same Apple Account.

**CloudKit schema.** On the owner's go-ahead, record type `Meeting` with
field `payload` (Bytes) was created in the CloudKit Console (Development)
and deployed to Production. The deploy diff showed only the new type, its
system fields and its default grants (`_creator` write, `_icloud` create,
`_world` read); `Dictation` and `Users` were unchanged. Production now
lists `Meeting` with `payload BYTES` and no extra indexes.
