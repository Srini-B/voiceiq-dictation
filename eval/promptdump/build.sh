#!/usr/bin/env bash
# Builds eval/promptdump/promptdump from the app's own PromptV1.swift, so the
# eval sends Gemini the exact prompt the app sends. Needs a Swift toolchain
# (macOS, or Linux via swiftly). Usage: eval/promptdump/build.sh [repo-root]
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
OUT="$ROOT/eval/promptdump/.build"
mkdir -p "$OUT"
BRIDGE="$ROOT/VoiceIQCore/Sources/Bridge"
swiftc -parse-as-library -emit-module -emit-library -static -module-name VoiceIQBridge \
  -emit-module-path "$OUT/VoiceIQBridge.swiftmodule" -o "$OUT/libVoiceIQBridge.a" \
  "$BRIDGE/DictationPlace.swift" "$BRIDGE/SurroundingText.swift" "$BRIDGE/FieldLayout.swift"
swiftc -I "$OUT" -L "$OUT" -lVoiceIQBridge -module-name PromptDump -o "$ROOT/eval/promptdump/promptdump" \
  "$ROOT"/VoiceIQCore/Sources/FormattingPipeline/*.swift "$ROOT/eval/promptdump/main.swift"
echo "built $ROOT/eval/promptdump/promptdump"
