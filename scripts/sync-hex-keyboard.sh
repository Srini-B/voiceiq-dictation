#!/usr/bin/env bash
# Copies Hex's keyboard, slide to type, English typing model and cleanup tagger
# into iOS/Keyboard/Hex and iOS/App/Hex.
#
#   scripts/sync-hex-keyboard.sh            sync to Hex's default branch (dev)
#   scripts/sync-hex-keyboard.sh <ref>      sync to a branch, tag or commit
#   scripts/sync-hex-keyboard.sh --check    report upstream commits not synced yet
#
# iOS/Keyboard/Hex/MANIFEST lists what is copied. Every destination is replaced
# wholesale, then iOS/Keyboard/Hex/patches/*.patch apply in name order, and
# iOS/Keyboard/Hex/UPSTREAM records the commit. --check exits 0 when up to date
# and 10 when Hex has new commits touching the manifest's paths.
# Works on Linux and macOS; needs git. Build and test after a sync:
# scripts/build-ios.sh and the keyboard tests.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEX_DIR="$ROOT/iOS/Keyboard/Hex"
MANIFEST="$HEX_DIR/MANIFEST"
UPSTREAM="$HEX_DIR/UPSTREAM"
REPO_URL="https://github.com/anomalyco/hex.git"
CACHE="${HEX_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/voiceiq/hex}"

check=0
ref=""
case "${1:-}" in
    --check) check=1 ;;
    "") ;;
    *) ref="$1" ;;
esac

if [ -d "$CACHE/.git" ]; then
    git -C "$CACHE" fetch --quiet --tags origin
else
    mkdir -p "$(dirname "$CACHE")"
    git clone --quiet "$REPO_URL" "$CACHE"
fi

git -C "$CACHE" remote set-head origin --auto >/dev/null
if [ -z "$ref" ]; then
    ref="$(git -C "$CACHE" symbolic-ref --short refs/remotes/origin/HEAD)"
    ref="${ref#origin/}"
fi

if git -C "$CACHE" rev-parse --verify --quiet "origin/$ref^{commit}" >/dev/null; then
    commit="$(git -C "$CACHE" rev-parse "origin/$ref^{commit}")"
else
    commit="$(git -C "$CACHE" rev-parse "$ref^{commit}")"
fi

paths=()
excludes=()
while read -r from to; do
    case "$from" in ''|'#'*) continue ;; esac
    if [ "$from" = exclude ]; then excludes+=("$to"); else paths+=("$from:$to"); fi
done < "$MANIFEST"
upstream_paths=()
for pair in "${paths[@]}"; do upstream_paths+=("${pair%%:*}"); done
pathspec=("${upstream_paths[@]}")
for path in "${excludes[@]}"; do pathspec+=(":(exclude)$path"); done

previous="$(sed -n 's/^commit=//p' "$UPSTREAM" 2>/dev/null || true)"

if [ "$check" = 1 ]; then
    if [ -z "$previous" ]; then
        echo "No recorded upstream commit; run a sync first."
        exit 10
    fi
    changes="$(git -C "$CACHE" log --oneline "$previous..$commit" -- "${pathspec[@]}")"
    if [ -z "$changes" ]; then
        echo "Up to date with Hex $ref (${commit:0:12})."
        exit 0
    fi
    echo "Hex $ref has $(printf '%s\n' "$changes" | wc -l | tr -d ' ') new commit(s) for the keyboard since ${previous:0:12}:"
    printf '%s\n' "$changes"
    echo
    git -C "$CACHE" diff --stat "$previous" "$commit" -- "${pathspec[@]}" | tail -n 1
    exit 10
fi

tree="$(mktemp -d)"
trap 'rm -rf "$tree"' EXIT
git -C "$CACHE" archive "$commit" "${upstream_paths[@]}" | tar -x -C "$tree"
for path in "${excludes[@]}"; do rm -rf "${tree:?}/$path"; done

# Start from empty copies, so files Hex deleted or the manifest dropped go too.
find "$HEX_DIR" -mindepth 1 -maxdepth 1 ! -name MANIFEST ! -name UPSTREAM ! -name patches -exec rm -rf {} +
rm -rf "$ROOT/iOS/App/Hex"
for pair in "${paths[@]}"; do
    from="${pair%%:*}"
    to="$ROOT/${pair#*:}"
    case "$to" in "$HEX_DIR"/*|"$ROOT/iOS/App/Hex"/*) ;; *) echo "MANIFEST destination outside the Hex folders: ${pair#*:}" >&2; exit 1 ;; esac
    mkdir -p "$(dirname "$to")"
    cp -R "$tree/$from" "$to"
done

shopt -s nullglob
for patch in "$HEX_DIR"/patches/*.patch; do
    echo "Applying ${patch#"$ROOT/"}"
    git -C "$ROOT" apply --whitespace=nowarn "$patch"
done
shopt -u nullglob

date="$(git -C "$CACHE" show -s --format=%cI "$commit")"
cat > "$UPSTREAM" <<EOF
# Written by scripts/sync-hex-keyboard.sh. Do not edit.
repository=https://github.com/anomalyco/hex
commit=$commit
committed=$date
EOF

if [ -n "$previous" ] && [ "$previous" != "$commit" ]; then
    echo "Hex commits since ${previous:0:12}:"
    git -C "$CACHE" log --oneline "$previous..$commit" -- "${pathspec[@]}"
fi
echo "Synced Hex keyboard to ${commit:0:12} ($date)."
