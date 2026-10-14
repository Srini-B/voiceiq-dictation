# 2026-10-14: Apple setup for History iCloud sync

## Why

History sync (`HistorySync.swift`, branch `typeless-parity`) needs the
CloudKit container `iCloud.io.blue.voiceiq`. The Mac and iPhone release
profiles had no container (`icloud-container-identifiers: []`), so a
Release build failed with "Provisioning profile doesn't support the
iCloud.io.blue.voiceiq iCloud Identifier". The owner asked for the normal
release flow (bump version, push to main) to work without further steps.

## What was done

1. Developer portal, in Chrome through cua-driver. The container did not
   exist; it was registered as "VoiceiQ" / `iCloud.io.blue.voiceiq`. It was
   then assigned to App IDs `io.blue.voiceiq` (2BTR7B9Y72) and
   `io.blue.voiceiq.ios` (WNRB5T63U6). Both pages show "Enabled iCloud
   Containers (1)" after a reload. The save marked both profiles INVALID.
2. Profiles, with asc. Deleted 7N753HA6AJ and C5UKV28AH5 and created them
   again under the same names and certificates: "VoiceiQ macOS Developer
   ID" is KPQCDRXGD7 (UUID 62a6dc49-…), "VoiceiQ iOS App Store" is
   JUZC4SG8PF (UUID e20ef96e-…). Both list the container. They are
   installed on the Mac mini and the old files were removed. The keyboard
   and Live Activity App IDs have only App Groups, so their profiles
   (JG93LD32SZ, KFA48KLAGZ) stayed as they were.
3. CloudKit Console. Created record type `Dictation` in Development with
   `text`, `appName`, `device`, `status` (String), `startedAt` (Date/Time)
   and `durationSeconds` (Double). The deploy diff showed only that type
   and its default grants. It was deployed, and Production lists
   "Dictation 12 fields". The `History` zone is created by the app.
4. `scripts/ci-plan-release.sh`: a manual dry run of the Release workflow
   on a version that is already tagged used to plan `release=false` and
   skip every build job. It now plans the build when `DRY_RUN=1`. Real
   releases still skip a tagged version.
5. `scripts/publish-github-release.sh`: the first branch dry run (run
   38497041202) passed plan, notes, ios and macos, then failed in publish
   with "release v0.6.0 already exists". In a dry run of a published
   version the script now continues and verifies a new appcast instead of
   the live one, which already lists that build. A real run still stops at
   that check (run locally: exit 1, same message).

## Verification

- `scripts/release.sh` on `typeless-parity` (0.6.0, build 45): tests pass,
  the Release build signs with the new profile, and the app and DMG are
  notarized ("Accepted"), stapled and accepted by Gatekeeper. The signed
  app has the container and `Production`.
- The notarized app was installed in /Applications and launched. It stays
  running. It logged "history sync started as Lobster's Mac mini", then
  "sent 250 row(s)" and "sent 52 row(s)" to the Production container with
  no CloudKit errors. The previous 0.6.0 app is kept in
  `.amp/in/backup/VoiceiQ.app` (not committed).
- `UPLOAD=none SKIP_TESTS=1 scripts/release-ios.sh`: archive and App Store
  export succeed. The app carries the container, `CloudKit` and
  `Production`; the extensions carry only the App Group. No build upload
  reservation was left behind.
- `scripts/ci-plan-release.sh`: with `EVENT=workflow_dispatch DRY_RUN=1` it
  plans 0.6.0 (45); without `DRY_RUN` and for a push that does not change
  the version it plans `release=false`, as before.
- GitHub: all seven secrets the workflow reads exist. CI downloads the
  profiles by name and ACTIVE state, so it gets the new ones without a
  change. The signing certificates are the same, so `SIGNING_P12_B64`
  still matches.

## Not verified

- The iPhone side of the round trip. It needs a TestFlight build with
  these entitlements on a device signed in to the same Apple Account.
