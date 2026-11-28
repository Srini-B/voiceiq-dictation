#!/bin/bash
# Queue for heavy jobs on the shared Mac mini: xcodebuild, swift test,
# simulator runs, release builds, signed installs and eval runs. At most two
# run at once; release-gating jobs go first, then merge gates, then the rest,
# first come first served within a class (activities/2026-11-28-mac-app-lock.md).
#
#   scripts/mac-queue.sh wait OWNER CLASS [NOTE]   joins the queue and returns
#                                                  when it is OWNER's turn
#   scripts/mac-queue.sh done OWNER                leaves the queue
#   scripts/mac-queue.sh show                      lists the queue in order
#
# CLASS: release (gates the next release), merge (gates a PR), other.
# OWNER is the thread ID. A ticket is dropped after 3 hours, so a thread that
# died doesn't hold a slot; run `wait` again to refresh a longer job.
# Shut down your simulators before `done`.
set -euo pipefail

dir=${VOICEIQ_MAC_QUEUE:-/Users/lobster/.mac-mini-queue}
slots=${VOICEIQ_MAC_SLOTS:-2}
expire=$((3 * 3600))
poll=${VOICEIQ_MAC_POLL:-60}
mkdir -p "$dir"

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
rank() { case $1 in release) echo 1;; merge) echo 2;; other) echo 3;; *) echo "class must be release, merge or other" >&2; exit 2;; esac; }

# Tickets are named <rank>-<epoch>-<owner>, so a plain sort is the queue order.
# A job that has started is renamed 0-…, so it keeps its slot until `done`.
prune() {
  local now t
  now=$(date +%s)
  for t in "$dir"/*; do
    [[ -e $t ]] || continue
    (( now - $(mtime "$t") > expire )) && rm -f "$t"
  done
  return 0
}
ticket_of() { ls "$dir" 2>/dev/null | grep -- "-$1\$" | head -1 || true; }
ahead() { ls "$dir" 2>/dev/null | sort | grep -n -x -- "$1" | cut -d: -f1; }

action=${1:?wait, done or show}
case $action in
wait)
  owner=${2:?owner (thread ID)}; class=${3:?release, merge or other}; note=${4:-}
  r=$(rank "$class")
  prune
  t=$(ticket_of "$owner")
  if [[ -z $t ]]; then
    t="$r-$(date +%s)-$owner"
    printf '%s\n%s\n' "$class" "$note" > "$dir/$t"
  else
    touch "$dir/$t"
    [[ $t == 0-* ]] && exit 0  # already running: refreshed
  fi
  while :; do
    prune
    [[ -e $dir/$t ]] || { printf '%s\n%s\n' "$class" "$note" > "$dir/$t"; }
    pos=$(ahead "$t")
    if (( pos <= slots )); then
      mv "$dir/$t" "$dir/0-$t"
      echo "mac queue: your turn ($class)" >&2
      exit 0
    fi
    echo "mac queue: position $pos ($((pos - slots)) ahead of a free slot); waiting" >&2
    sleep "$poll"
  done
  ;;
done)
  owner=${2:?owner (thread ID)}
  t=$(ticket_of "$owner")
  [[ -n $t ]] && rm -f "$dir/$t"
  exit 0
  ;;
show)
  prune
  ls "$dir" | sort | nl
  ;;
*)
  echo "usage: $0 wait OWNER CLASS [NOTE] | done OWNER | show" >&2
  exit 2
  ;;
esac
