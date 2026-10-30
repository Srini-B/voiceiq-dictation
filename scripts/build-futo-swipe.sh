#!/bin/bash
# Builds FUTO Swipe (swipe-library, GPL-3.0, with ExecuTorch, BSD) for the
# iPhone and its Simulator, and fetches the FUTO Swipe models (FUTO Model
# Weights License 1.0). Output, committed so app builds need neither:
#   iOS/Vendor/FUTOSwipe/include         the library's public headers
#   iOS/Vendor/FUTOSwipe/lib/<sdk>/      libfutoswipe_registry.a (force-loaded:
#                                        ops and backend register themselves)
#                                        and libfutoswipe.a
#   iOS/Keyboard/Resources/swipe/        encoder, decoder, context LM
# Takes about 15 minutes; needs Xcode, CMake and Python 3.10 or later.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$HOME/Library/Caches/voiceiq-futo-swipe"
LIBRARY_COMMIT=1b13f2c85d6b347f6ea3fbc4b3aaf01fce42429a
MODELS_REVISION=315d42583233b71d75665d076cfa2f2c7c6f43ad
TORCH_VERSION=2.10.0
VENDOR="$ROOT/iOS/Vendor/FUTOSwipe"
SRC="$CACHE/swipe-library"
ET="$SRC/third_party/executorch"

if [ ! -d "$SRC/.git" ]; then
  git clone https://gitlab.futo.org/keyboard/swipe-library.git "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$LIBRARY_COMMIT" || true
git -C "$SRC" checkout --quiet "$LIBRARY_COMMIT"
git -C "$SRC" submodule update --init --recursive --depth 1

# The library's own ExecuTorch fixes (its Makefile's patch-et step).
for patch in "$SRC"/patches/*.patch; do
  git -C "$ET" apply --reverse --check "$patch" 2>/dev/null || git -C "$ET" apply "$patch"
done
perl -pi -e 's/static char hexdigits\[16\]/static char hexdigits[17]/' \
  "$ET/third-party/flatcc/include/flatcc/portable/grisu3_print.h"
# flatc and flatcc are Mac tools built during the iOS build, but they inherit
# the iOS deployment target (17.0), which is not a macOS version.
perl -pi -e 's/CMAKE_OSX_DEPLOYMENT_TARGET:STRING=\$\{CMAKE_OSX_DEPLOYMENT_TARGET\}/CMAKE_OSX_DEPLOYMENT_TARGET:STRING=12.0/' \
  "$ET/third-party/CMakeLists.txt"

# ExecuTorch's kernel code generation needs torchgen, which ships in torch.
VENV="$CACHE/venv"
if [ ! -x "$VENV/bin/python3" ]; then
  PYTHON="$(command -v python3.12 || command -v python3.13 || uv python find 3.12)"
  "$PYTHON" -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip cmake pyyaml typing_extensions
  "$VENV/bin/pip" download --quiet --no-deps "torch==$TORCH_VERSION" \
    --index-url https://download.pytorch.org/whl/cpu -d "$VENV/tmp"
  "$VENV/bin/python3" -c "import zipfile,glob,sysconfig; z=zipfile.ZipFile(glob.glob('$VENV/tmp/torch-*.whl')[0]); [z.extract(n, sysconfig.get_path('purelib')) for n in z.namelist() if n.startswith('torchgen/')]"
  rm -rf "$VENV/tmp"
fi

OPS="$(cat "$SRC"/models/*/ops.txt | sort -u | grep -v '^$' | paste -sd, -)"
TOOLCHAIN="$ET/third-party/ios-cmake/ios.toolchain.cmake"
ET_FLAGS=(
  -DPYTHON_EXECUTABLE="$VENV/bin/python3"
  -DEXECUTORCH_BUILD_XNNPACK=ON
  -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON
  -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON -DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON
  -DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON
  -DEXECUTORCH_BUILD_KERNELS_QUANTIZED=OFF -DEXECUTORCH_BUILD_COREML=OFF -DEXECUTORCH_BUILD_MPS=OFF
  -DEXECUTORCH_BUILD_VULKAN=OFF -DEXECUTORCH_BUILD_TESTS=OFF -DEXECUTORCH_BUILD_EXAMPLES=OFF
  -DEXECUTORCH_OPTIMIZE_SIZE=ON -DEXECUTORCH_SELECT_OPS_LIST="$OPS"
  -DXNNPACK_BUILD_ALL_MICROKERNELS=OFF -DXNNPACK_ENABLE_SPARSE=OFF
  -DXNNPACK_BUILD_TESTS=OFF -DXNNPACK_BUILD_BENCHMARKS=OFF
  -DXNNPACK_ENABLE_ARM_SME=OFF -DXNNPACK_ENABLE_ARM_SME2=OFF
)

rm -rf "$VENDOR/lib" "$VENDOR/include"
for pair in iphoneos:OS64 iphonesimulator:SIMULATORARM64; do
  sdk="${pair%%:*}"; platform="${pair##*:}"
  common=(-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DPLATFORM="$platform" -DDEPLOYMENT_TARGET=17.0
          -DENABLE_BITCODE=OFF -DCMAKE_BUILD_TYPE=Release)
  out="$CACHE/et-$sdk"
  "$VENV/bin/cmake" -S "$ET" -B "$out" "${common[@]}" "${ET_FLAGS[@]}" > "$CACHE/et-$sdk.log"
  "$VENV/bin/cmake" --build "$out" -j 8 >> "$CACHE/et-$sdk.log"
  lib="$CACHE/lib-$sdk"
  "$VENV/bin/cmake" -S "$SRC" -B "$lib" "${common[@]}" -DET_BUILD="$out" -DUSE_MARCH_NATIVE=OFF > "$CACHE/lib-$sdk.log"
  "$VENV/bin/cmake" --build "$lib" --target swipe_decoder -j 8 >> "$CACHE/lib-$sdk.log"

  dest="$VENDOR/lib/$sdk"
  mkdir -p "$dest"
  libtool -static -o "$dest/libfutoswipe_registry.a" \
    "$out/libexecutorch.a" "$out/libexecutorch_selected_kernels.a" "$out/backends/xnnpack/libxnnpack_backend.a"
  libtool -static -o "$dest/libfutoswipe.a" "$lib/libswipe_decoder.a" \
    "$out"/extension/{module/libextension_module_static,tensor/libextension_tensor,data_loader/libextension_data_loader,flat_tensor/libextension_flat_tensor,named_data_map/libextension_named_data_map,threadpool/libextension_threadpool}.a \
    "$out/libexecutorch_core.a" "$out/kernels/portable/libportable_kernels.a" \
    "$out"/backends/xnnpack/third-party/XNNPACK/{libXNNPACK,libxnnpack-microkernels-prod}.a \
    "$out/backends/xnnpack/third-party/pthreadpool/libpthreadpool.a" \
    "$out/backends/xnnpack/third-party/cpuinfo/libcpuinfo.a" \
    $(ls "$out/third-party/flatcc_ep/lib/libflatccrt.a" "$out/kleidiai/libkleidiai.a" 2>/dev/null)
  strip -S "$dest"/*.a
done

mkdir -p "$VENDOR/include"
cp -R "$SRC/include/swipe_decoder" "$VENDOR/include/"
cp "$SRC/LICENSE" "$VENDOR/LICENSE"
echo "swipe-library $LIBRARY_COMMIT (https://gitlab.futo.org/keyboard/swipe-library), built by scripts/build-futo-swipe.sh" > "$VENDOR/SOURCE"

MODELS="$ROOT/iOS/Keyboard/Resources/swipe"
for file in honorable_sturgeon/model_fp32.pte honorable_sturgeon/metadata.json \
            magic_macaw/model_fp32.pte magic_macaw/metadata.json \
            hungry_jellyfish/context_lm.pte hungry_jellyfish/metadata.json hungry_jellyfish/vocab.txt LICENSE.md; do
  mkdir -p "$MODELS/$(dirname "$file")"
  curl -sfL -o "$MODELS/$file" "https://huggingface.co/futo-org/futo-swipe/resolve/$MODELS_REVISION/$file"
done
echo "✓ FUTO Swipe built: $(du -sh "$VENDOR/lib" | cut -f1) of libraries, $(du -sh "$MODELS" | cut -f1) of models and dictionary"
