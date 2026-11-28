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

# A path that vanished reads as just now. BSD stat (macOS) or GNU stat.
if stat -f %m / >/dev/null 2>&1 && ! stat -c %Y / >/dev/null 2>&1; then
  mtime() { stat -f %m "$1" 2>/dev/null || date +%s; }
else
  mtime() { stat -c %Y "$1" 2>/dev/null || date +%s; }
fi
rank() { case $1 in release) echo 1;; merge) echo 2;; other) echo 3;; *) echo "class must be release, merge or other" >&2; exit 2;; esac; }

# Tickets are named <rank>-<sequence>-<owner>, with a sequence number handed
# out under the lock, so a plain sort is the queue order.
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
# Joining the queue and the check-then-start step run under one lock, so a
# later arrival can't change the order between another waiter's check and
# its start. The lock is a kernel file lock (flock) held by the step's own
# process, so a killed process can't leave it behind.
run_locked() {
  perl -e 'use Fcntl qw(:flock); $^F = 255; open(my $f, ">>", shift) or die "lock: $!"; flock($f, LOCK_EX) or die "lock: $!"; exec @ARGV or die "exec: $!"' "$dir.lock" "$0" "$@"
}
# The owner is everything after "[0-]<rank>-<sequence>-", compared literally.
# Prints every ticket the owner has, oldest name first. Tickets from before
# the 9-digit sequence carry a 10-digit timestamp there; they match too, so
# `done` clears them.
tickets_of() {
  local f
  for f in $(ls "$dir" 2>/dev/null); do
    [[ $f =~ ^(0-)?[0-9]-[0-9]+-(.*)$ && ${BASH_REMATCH[2]} == "$1" ]] && echo "$f"
  done
  return 0
}
ahead() { ls "$dir" 2>/dev/null | sort | grep -n -x -F -- "$1" | cut -d: -f1; }

action=${1:?wait, done or show}
case $action in
_join)  # under the lock: prints the ticket; exits 3 if it is already running
  owner=$2 class=$3 note=${4:-}
  prune
  t=$(tickets_of "$owner" | head -1)
  if [[ -z $t ]]; then
    n=$(( $(cat "$dir.seq" 2>/dev/null || echo 0) + 1 )); echo $n > "$dir.seq"
    t="$(rank "$class")-$(printf %09d $n)-$owner"
    printf '%s\n%s\n' "$class" "$note" > "$dir/$t"
  else
    touch "$dir/$t"
  fi
  echo "$t"
  [[ $t == 0-* ]] && exit 3
  exit 0
  ;;
_turn)  # under the lock: starts the ticket if it is in a slot, else prints its position
  t=$2 class=$3 note=${4:-}
  prune
  # A live waiter keeps its ticket fresh, and a job that starts gets a full
  # 3-hour lease from its start, not from when it joined.
  if [[ -e $dir/$t ]]; then touch "$dir/$t"; else printf '%s\n%s\n' "$class" "$note" > "$dir/$t"; fi
  pos=$(ahead "$t")
  if (( pos <= slots )); then mv "$dir/$t" "$dir/0-$t"; touch "$dir/0-$t"; exit 0; fi
  echo "$pos"
  exit 1
  ;;
wait)
  owner=${2:?owner (thread ID)}; class=${3:?release, merge or other}; note=${4:-}
  rank "$class" >/dev/null
  rc=0; t=$(run_locked _join "$owner" "$class" "$note") || rc=$?
  (( rc == 3 )) && exit 0  # already running: refreshed
  (( rc == 0 )) || exit $rc
  while :; do
    if pos=$(run_locked _turn "$t" "$class" "$note"); then
      echo "mac queue: your turn ($class)" >&2
      exit 0
    fi
    echo "mac queue: position $pos ($((pos - slots)) ahead of a free slot); waiting" >&2
    sleep "$poll"
  done
  ;;
done)
  owner=${2:?owner (thread ID)}
  for t in $(tickets_of "$owner"); do rm -f "$dir/$t"; done
  exit 0
  ;;
_prune)  # under the lock
  prune
  ;;
show)
  run_locked _prune
  ls "$dir" | sort | nl
  ;;
*)
  echo "usage: $0 wait OWNER CLASS [NOTE] | done OWNER | show" >&2
  exit 2
  ;;
esac
