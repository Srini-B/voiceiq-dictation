#!/bin/zsh
# On a Mac: transcribe every eval clip with Parakeet v3 (Fluid Speech Pro) through the FluidAudio
# CLI, with and without the Dictionary's CTC rescoring. Usage: run_parakeet.sh <audio dir> <out dir> <vocab file> <label> [extra flags]
set -u
cli=${FLUIDAUDIO_CLI:-~/fa/.build/release/fluidaudiocli}
audio=$1 out=$2 vocab=$3 label=$4
shift 4
mkdir -p "$out/$label"
ok=0 failed=0
for wav in "$audio"/*.wav; do
  id=${wav:t:r}
  if [[ $vocab == none ]]; then
    $cli transcribe "$wav" --model-version v3 --output-json "$out/$label/$id.json" "$@" >/dev/null
  else
    $cli transcribe "$wav" --model-version v3 --custom-vocab "$vocab" --output-json "$out/$label/$id.json" "$@" >/dev/null
  fi
  if [[ $? -eq 0 ]]; then
    ok=$((ok + 1))
  else
    echo "failed: $id" >&2
    failed=$((failed + 1))
  fi
done
echo "$ok transcribed, $failed failed"
[[ $failed -eq 0 ]] || exit 1
