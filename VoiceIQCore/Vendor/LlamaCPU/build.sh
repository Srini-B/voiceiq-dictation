#!/bin/zsh
# Rebuilds CLlama.xcframework: llama.cpp at a pinned release, CPU only, as one
# static library for iPhone and iPad (arm64) and the iOS Simulator.
# The iPhone app runs VoiceIQ Writer with it in the background voice session,
# where iOS forbids GPU work, so Metal is not built at all. The official
# release xcframework has no simulator slice and carries Metal.
#
# Needs git, cmake and Xcode. Output replaces CLlama.xcframework next to this
# script; commit it.
set -euo pipefail

TAG=b12198
REVISION=f477f795cb071baf5b8af6488378366a72034ac4
IOS_MIN=17.0
# Dot-product instructions: every iPhone that runs iOS 26 or later (A13 and
# up). LocalWriterModel.available hides the writer on older chips.
ARM_ARCH=armv8.2-a+dotprod+fp16
HERE=${0:A:h}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp.git "$WORK/src"
[[ $(git -C "$WORK/src" rev-parse HEAD) == "$REVISION" ]] || { echo "$TAG is not $REVISION" >&2; exit 1; }

# The Simulator slice is fat because Xcode builds the iOS Simulator app for
# x86_64 as well; only arm64 runs the writer (LocalModelSupport).
for TARGET in iphoneos:arm64 iphonesimulator:arm64 iphonesimulator:x86_64; do
  SDK=${TARGET%%:*} ARCH=${TARGET##*:}
  CPU_ARGS=()
  [[ $ARCH == arm64 ]] && CPU_ARGS=(-DGGML_CPU_ARM_ARCH=$ARM_ARCH)
  cmake -S "$WORK/src" -B "$WORK/build-$SDK-$ARCH" -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$SDK -DCMAKE_OSX_ARCHITECTURES=$ARCH \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF "${CPU_ARGS[@]}" \
    -DGGML_METAL=OFF -DGGML_BLAS=OFF -DGGML_ACCELERATE=OFF -DGGML_OPENMP=OFF \
    -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_OPENSSL=OFF \
    >/dev/null
  cmake --build "$WORK/build-$SDK-$ARCH" --config Release -j 8 --target llama >/dev/null
  libtool -static -o "$WORK/libllama-$SDK-$ARCH.a" $(find "$WORK/build-$SDK-$ARCH" -name '*.a') 2>/dev/null
  strip -S "$WORK/libllama-$SDK-$ARCH.a" 2>/dev/null
done
mv "$WORK/libllama-iphoneos-arm64.a" "$WORK/libllama-iphoneos.a"
lipo -create "$WORK/libllama-iphonesimulator-arm64.a" "$WORK/libllama-iphonesimulator-x86_64.a" \
  -output "$WORK/libllama-iphonesimulator.a"

mkdir "$WORK/include"
cp "$WORK/src/include/llama.h" "$WORK/src/ggml/include/"{ggml,ggml-cpu,ggml-backend,ggml-alloc,ggml-opt,gguf}.h "$WORK/include/"
cat > "$WORK/include/module.modulemap" <<EOF
module CLlama {
    header "llama.h"
    link "c++"
    export *
}
EOF

rm -rf "$HERE/CLlama.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/libllama-iphoneos.a" -headers "$WORK/include" \
  -library "$WORK/libllama-iphonesimulator.a" -headers "$WORK/include" \
  -output "$HERE/CLlama.xcframework" >/dev/null
cp "$WORK/src/LICENSE" "$HERE/LICENSE"
echo "Built $HERE/CLlama.xcframework from llama.cpp $TAG"
