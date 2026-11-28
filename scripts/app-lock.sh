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
age() { echo $(( $(date +%s) - $(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || date +%s) )); }

case $action in
acquire)
  while ! mkdir "$lock" 2>/dev/null; do
    if [[ $(held_by) == "$owner" ]]; then break; fi
    if (( $(age) >= stale )); then
      # One owner at a time reclaims a stale lock and checks it again inside,
      # so a contender can't delete the fresh lock another owner just took.
      if mkdir "$lock.takeover" 2>/dev/null; then
        if [[ -d $lock ]] && (( $(age) >= stale )); then
          echo "app lock: taking over a stale lock from $(held_by)" >&2
          rm -rf "$lock"
        fi
        rmdir "$lock.takeover"
      elif (( $(date +%s) - $(stat -c %Y "$lock.takeover" 2>/dev/null || stat -f %m "$lock.takeover" 2>/dev/null || date +%s) > 60 )); then
        rmdir "$lock.takeover" 2>/dev/null || true
      else
        sleep 1
      fi
      continue
    fi
    echo "app lock: held by $(held_by) for $(age)s; waiting" >&2
    sleep 30
  done
  printf '%s\n%s\n' "$owner" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock/owner"
  touch "$lock"
  ;;
release)
  if [[ $(held_by) == "$owner" ]]; then rm -rf "$lock"; fi
  ;;
*)
  echo "usage: $0 acquire|release OWNER" >&2
  exit 2
  ;;
esac
