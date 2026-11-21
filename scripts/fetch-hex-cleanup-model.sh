#!/bin/sh
# Downloads Hex's cleanup tagger Core ML model (about 25 MB, a Hex release asset kept
# out of git) into iOS/App/HexCleanupModel and checks its SHA-256. The tag, asset and
# hash come from Hex's own fetch script, which scripts/sync-hex-keyboard.sh copies to
# iOS/App/Hex/Cleanup/fetch-cleanup-model.sh, so a sync that moves Hex to a new model
# moves this download with it. Run before `xcodegen generate`; a current copy is kept.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
upstream="$root/iOS/App/Hex/Cleanup/fetch-cleanup-model.sh"
value() { sed -n "s/^$1=//p" "$upstream" | head -n 1; }
tag=$(value tag)
asset=$(value asset)
sha256=$(value sha256)
if [ -z "$tag" ] || [ -z "$asset" ] || [ -z "$sha256" ]; then
  echo "Could not read tag, asset and sha256 from $upstream" >&2
  exit 1
fi

destination="$root/iOS/App/HexCleanupModel"
stamp="$destination/.HexCleanupTagger.sha256"
if [ -d "$destination/HexCleanupTagger.mlpackage" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$sha256" ]; then
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL --retry 3 -o "$work/$asset" "https://github.com/anomalyco/hex/releases/download/$tag/$asset"
if command -v shasum >/dev/null; then
  echo "$sha256  $work/$asset" | shasum -a 256 -c - >/dev/null
else
  echo "$sha256  $work/$asset" | sha256sum -c - >/dev/null
fi
rm -rf "$destination"
mkdir -p "$destination"
unzip -q "$work/$asset" -d "$destination"
echo "$sha256" > "$stamp"
echo "Hex cleanup tagger model $tag ready"
