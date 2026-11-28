#!/bin/zsh
# Copies a probed meeting's files and prints each track's length and silence.
# Usage: collect.sh MEETING_FOLDER OUT_DIR
set -euo pipefail

folder=$1 out=$2
mkdir -p $out
for file in mic.caf system.caf meta.json transcript.json notes.json screen-names.json; do
  [[ -e $folder/$file ]] && cp $folder/$file $out/
done
for track in mic system; do
  [[ -e $out/$track.caf ]] || { echo "$track: missing"; continue; }
  length=$(afinfo $out/$track.caf | awk '/estimated duration/ {print $3}')
  # Share of 100 ms windows below -50 dBFS.
  silence=$(ffmpeg -nostdin -loglevel error -i $out/$track.caf -af "silencedetect=n=-50dB:d=0.1" -f null - 2>&1 \
    | awk -v total=$length '/silence_duration/ {sum += $NF} END {printf "%.0f%%", total > 0 ? 100 * sum / total : 0}')
  echo "$track: ${length}s, silent $silence"
done
