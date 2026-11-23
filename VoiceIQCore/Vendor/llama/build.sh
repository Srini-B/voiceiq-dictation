#!/bin/zsh
# Builds Vendor/llama/llama.xcframework: llama.cpp's text runtime (llama +
# ggml with the CPU, Accelerate and Metal backends) as one static library per
# platform, for the on-device writer (LFM3-Omni-2B). llama.cpp's release
# xcframework has no iOS Simulator slice, so the app could not build for the
# Simulator with it. Multimodal (mtmd), the tools and the server are left out.
# BLAS (Accelerate) is off: with it, a system prompt restored from the saved
# prefix gave a different answer than the same prompt read again, and the
# Simulator read prompts ten times slower than the Mac.
#
# Usage: VoiceIQCore/Vendor/llama/build.sh   (needs Xcode and cmake)
set -euo pipefail

TAG=b12633
COMMIT=9c10c94e16ebc4f3ed7c06264a93bf7e019c3f26
HERE=${0:A:h}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Headers in a llama/ subfolder: SwiftPM copies every library's headers into
# one include folder, where CVoiceIQAEC's module map already sits at the top.
mkdir -p "$WORK/headers/llama"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$WORK/src"
[[ $(git -C "$WORK/src" rev-parse HEAD) == "$COMMIT" ]] || { echo "llama.cpp $TAG is not $COMMIT"; exit 1; }

# name, CMAKE_SYSTEM_NAME, sysroot, architecture, deployment target, ARM
# features. ggml's quantized CPU kernels need the dot-product instructions
# (every Apple silicon Mac; A13 and later, which `LocalWriterSupport` checks)
# to read a prompt in seconds rather than tens of seconds. iPhone and iPad
# always write on the CPU; the Mac falls back to it for what Metal cannot run.
# The Mac app's Release build is universal: its two halves are joined below.
slices=(
  "macos-arm64|Darwin|macosx|arm64|14.0|armv8.2-a+dotprod+fp16"
  "macos-x86_64|Darwin|macosx|x86_64|14.0|"
  "ios|iOS|iphoneos|arm64|18.0|armv8.2-a+dotprod+fp16"
  "ios-simulator|iOS|iphonesimulator|arm64|18.0|armv8.2-a+dotprod+fp16"
)
for slice in $slices; do
  IFS='|' read -r name system sdk arch version arm <<< "$slice"
  build="$WORK/build-$name"
  cmake -S "$WORK/src" -B "$build" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME="$system" \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$version" \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF \
    -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH="$arm" -DGGML_OPENMP=OFF -DGGML_ACCELERATE=ON \
    -DGGML_BLAS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON > "$WORK/$name.log"
  cmake --build "$build" --config Release -j "$(sysctl -n hw.ncpu)" --target llama >> "$WORK/$name.log"
  out="$WORK/out-$name"
  mkdir -p "$out"
  libtool -static -o "$out/libllama.a" $(find "$build" -name '*.a') 2> /dev/null
  strip -S "$out/libllama.a"
done

mkdir -p "$WORK/out-macos"
lipo -create "$WORK/out-macos-arm64/libllama.a" "$WORK/out-macos-x86_64/libllama.a" -output "$WORK/out-macos/libllama.a"
libs=()
for name in macos ios ios-simulator; do
  libs+=(-library "$WORK/out-$name/libllama.a" -headers "$WORK/headers")
done

cp "$WORK/src/include/llama.h" "$WORK/src/ggml/include/"{ggml,ggml-alloc,ggml-backend,ggml-cpu,ggml-metal,ggml-opt,gguf}.h "$WORK/headers/llama/"
cat > "$WORK/headers/llama/module.modulemap" <<'EOF'
module llama {
    header "llama.h"
    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "MetalKit"
    link framework "Foundation"
    export *
}
EOF

rm -rf "$HERE/llama.xcframework"
xcodebuild -create-xcframework $libs -output "$HERE/llama.xcframework" > /dev/null
cp "$WORK/src/LICENSE" "$HERE/LICENSE"
du -sh "$HERE/llama.xcframework"
