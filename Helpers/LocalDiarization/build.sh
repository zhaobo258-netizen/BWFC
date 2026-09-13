#!/usr/bin/env bash
# 构建 bangwo-local-diarization 本地分人引擎（macOS arm64，仅 CLT，无 Xcode）。
#
# sherpa-onnx 共享库解析顺序：
#   1) $BWFX_SHERPA_LIB_DIR（显式指定，含 libsherpa-onnx-c-api.dylib + libonnxruntime.dylib）
#   2) "$ROOT/build/engine-deps/lib"（首次自动下载 v1.13.8 pinned release，带 --fail）
#
# 打包模式：BWFX_ENGINE_RPATH=@executable_path/../Frameworks Scripts/build_engine.sh
#   （dylib 需另行拷入 .app/Contents/Frameworks/，见 Scripts/make_app.sh）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEPS_LIB="$ROOT/build/engine-deps/lib"
SHERPA_VERSION="1.13.8"

if [[ -z "${BWFX_SHERPA_LIB_DIR:-}" ]]; then
    mkdir -p "$DEPS_LIB"
    if [[ ! -f "$DEPS_LIB/libsherpa-onnx-c-api.dylib" || ! -f "$DEPS_LIB/libonnxruntime.dylib" ]]; then
        echo "==> 下载 sherpa-onnx v$SHERPA_VERSION osx-arm64 共享库（pinned）"
        TARBALL="$ROOT/build/engine-deps/sherpa-onnx.tar.bz2"
        curl -fL --retry 3 --retry-delay 2 -o "$TARBALL" \
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}/sherpa-onnx-v${SHERPA_VERSION}-osx-arm64-shared-no-tts-lib.tar.bz2"
        tar xjf "$TARBALL" -C "$ROOT/build/engine-deps/"
        cp "$ROOT"/build/engine-deps/sherpa-onnx-v*/lib/*.dylib "$DEPS_LIB/"
        rm -f "$TARBALL"
        rm -rf "$ROOT"/build/engine-deps/sherpa-onnx-v*/
    fi
    BWFX_SHERPA_LIB_DIR="$DEPS_LIB"
fi
LIB_DIR="$(cd "$BWFX_SHERPA_LIB_DIR" && pwd)"

RPATH="${BWFX_ENGINE_RPATH:-$LIB_DIR}"
OUT="${BWFX_ENGINE_OUT:-$HERE/bangwo-local-diarization}"

swiftc -O -lc++ \
    -I "$HERE/include" \
    -import-objc-header "$HERE/SherpaOnnx-Bridging-Header.h" \
    "$HERE/bangwo-local-diarization.swift" \
    -L "$LIB_DIR" -l sherpa-onnx-c-api -l onnxruntime \
    -Xlinker -rpath -Xlinker "$RPATH" \
    -o "$OUT"

codesign -f -s - "$OUT"
echo "ENGINE_BUILD_OK: $OUT (rpath=$RPATH)"
