# Test switch for iCloud sync (2026-11-28)

**Why:** at 20:03 IST a gate run on the Mac mini launched the signed
/Applications/VoiceiQ.app while a redesign worker's seed data (C0FFEE IDs)
was in the real data folder, and it reached the owner's iCloud. The same
day's live-call probe meetings ("Product Design Brainstorm" and earlier
rounds) had already synced: meeting and History sync are always on in every
signed build, with no setting.

**Decision (integrator T-0118f343):**
- Delete the probe meetings from the Mac app under the app lock.
- Run probes in an isolated copy, ~/Applications/VoiceiQ-probe.app
  (io.blue.voiceiq.probe), ad hoc signed without the iCloud entitlement.
- Add a `DebugDisableCloudSync` default that keeps all five syncs off, so
  tests on the real signed app are safe. It gets no user-facing switch.

**What changed:**
- `CloudSync.isDisabledForTests` is read once at launch and logs a notice.
  The Mac menu and the iPhone's Settings show "Sync off (test)".
- docs/DEBUG_LOG.md has the commands, and the caveat that changes made while
  it is on upload once it is off.
