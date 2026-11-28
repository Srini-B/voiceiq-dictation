#!/bin/zsh
# Copies a probed meeting's files and prints each track's length against the
# recording's, its share of silence, and its runs of digital silence (gaps).
# Usage: collect.sh MEETING_FOLDER OUT_DIR
set -euo pipefail

folder=$1 out=$2
mkdir -p $out
for file in mic.caf mic-aec.caf system.caf meta.json transcript.json notes.json screen-names.json; do
  if [[ -e $folder/$file ]]; then cp $folder/$file $out/; fi
done
[[ -e $out/meta.json ]] && echo "recording: $(python3 -c 'import json, sys; print(round(json.load(open(sys.argv[1]))["durationSeconds"], 1))' $out/meta.json)s"

# Sums silencedetect's runs, counting one still open at the end of the file.
silence() { # file threshold-dB minimum-seconds total-seconds
  ffmpeg -nostdin -hide_banner -i $1 -af "silencedetect=n=$2dB:d=$3" -f null - 2>&1 \
    | awk -v total=$4 '
        /silence_start/ { start = $NF; open = 1 }
        /silence_end/ { sum += $NF; runs++; if ($NF > longest) longest = $NF; open = 0 }
        END { if (open) { run = total - start; sum += run; runs++; if (run > longest) longest = run }
              printf "%.0f%% in %d runs, longest %.1fs", (total > 0 ? 100 * sum / total : 0), runs, longest }'
}

for track in mic system; do
  [[ -e $out/$track.caf ]] || { echo "$track: missing"; continue; }
  length=$(afinfo $out/$track.caf | awk '/estimated duration/ {print $3}')
  echo "$track: ${length}s; below -50 dBFS for 0.1s+: $(silence $out/$track.caf -50 0.1 $length); digital silence for 0.2s+ (gaps): $(silence $out/$track.caf -90 0.2 $length)"
done
