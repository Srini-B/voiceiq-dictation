#!/bin/bash
# Lock for the installed /Applications/VoiceiQ.app on a shared test Mac.
# Take it before quitting, installing or replacing the app; release it when
# done. Agents that quit or reinstalled the app under each other broke two
# test runs on 2026-11-28 (activities/2026-11-28-mac-app-lock.md).
#
#   scripts/app-lock.sh acquire OWNER   waits while another owner holds a lock
#                                       under 30 minutes old; a lock that old
#                                       is stale and taken over
#   scripts/app-lock.sh release OWNER   removes the lock if OWNER holds it
#
# OWNER is the thread ID or another name a person can trace. Tests that don't
# need the real install should use their own copy, such as
# ~/Applications/VoiceiQ-<owner>.app, and skip the lock.
set -euo pipefail

lock=${VOICEIQ_APP_LOCK:-/Users/lobster/.voiceiq-app.lock}
stale=$((30 * 60))
action=${1:?acquire or release}
owner=${2:?owner (thread ID)}

held_by() { cat "$lock/owner" 2>/dev/null | head -1; }
# A path that vanished reads as just now. BSD stat (macOS) or GNU stat.
if stat -f %m / >/dev/null 2>&1 && ! stat -c %Y / >/dev/null 2>&1; then
  mtime() { stat -f %m "$1" 2>/dev/null || date +%s; }
else
  mtime() { stat -c %Y "$1" 2>/dev/null || date +%s; }
fi
age() { echo $(( $(date +%s) - $(mtime "$lock") )); }

# Reclaiming a stale lock and releasing one both check the owner, then
# delete. They run under one kernel file lock (flock), held by the step's own
# process, so neither can delete a fresh lock another owner just took and a
# killed process can't leave the file lock behind.
run_locked() {
  perl -e 'use Fcntl qw(:flock); $^F = 255; open(my $f, ">>", shift) or die "lock: $!"; flock($f, LOCK_EX) or die "lock: $!"; exec @ARGV or die "exec: $!"' "$lock.flock" "$0" "$@"
}

case $action in
acquire)
  [[ -d $(dirname "$lock") ]] || { echo "app lock: $(dirname "$lock") does not exist" >&2; exit 1; }
  while ! mkdir "$lock" 2>/dev/null; do
    # Renewing your own lock runs under the file lock, so a stale-lock
    # reclaim can't delete it between the check and the touch.
    if [[ $(held_by) == "$owner" ]] && run_locked _renew "$owner"; then exit 0; fi
    [[ -d $lock ]] || continue  # released since the mkdir: try again now
    if (( $(age) >= stale )); then
      run_locked _reclaim "$owner"
      continue
    fi
    # No owner yet, or being deleted: another owner is mid-acquire or
    # mid-release, so look again in a second.
    if [[ -z $(held_by) ]]; then sleep 1; continue; fi
    echo "app lock: held by $(held_by) for $(age)s; waiting" >&2
    sleep 30
  done
  printf '%s\n%s\n' "$owner" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock/owner"
  touch "$lock"
  ;;
release)
  run_locked _release "$owner"
  ;;
_reclaim)  # under the file lock
  if [[ -d $lock ]] && (( $(age) >= stale )); then
    echo "app lock: taking over a stale lock from $(held_by)" >&2
    rm -rf "$lock"
  fi
  ;;
_renew)  # under the file lock: refreshes the lock if OWNER still holds it
  [[ $(held_by) == "$owner" ]] || exit 1
  printf '%s\n%s\n' "$owner" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock/owner"
  touch "$lock"
  ;;
_release)  # under the file lock
  if [[ $(held_by) == "$owner" ]]; then rm -rf "$lock"; fi
  ;;
*)
  echo "usage: $0 acquire|release OWNER" >&2
  exit 2
  ;;
esac
