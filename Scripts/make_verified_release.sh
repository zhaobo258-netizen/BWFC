#!/bin/bash
# 《帮我分析》已验证发布 .app 打包脚本（原生 swiftc 构建，无 SwiftPM / Xcode）
# 仅在一个全新临时目录内组装产物；不删除历史产物、不安装、不启动、不碰用户数据/设置。
# 用法：Scripts/make_verified_release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY_NAME="BangWoFenXi"
SRC_DIRS=("$ROOT/App" "$ROOT/Models" "$ROOT/Features" "$ROOT/Core")
INFO_PLIST="$ROOT/Resources/Info.plist"
ENTITLEMENTS="$ROOT/Entitlements.plist"
ICON="$ROOT/Resources/AppIcon.icns"
SIGNING_IDENTITY="BangWoFenXi Local Code Signing"
TARGET="arm64-apple-macosx26.0"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "错误：Info.plist 中版本号无效：$APP_VERSION" >&2
    exit 1
fi
if [[ ! "$BUILD_NUM" =~ ^[0-9]+$ ]]; then
    echo "错误：Info.plist 中 build 号无效：$BUILD_NUM" >&2
    exit 1
fi

# 签名前先校验稳定身份存在（禁止 ad-hoc）
if ! security find-identity -v -p codesigning \
    | grep -Fq "\"$SIGNING_IDENTITY\""; then
    echo "错误：未找到稳定签名身份 \"$SIGNING_IDENTITY\"；拒绝打包。" >&2
    echo "不得使用 BWFX_CODESIGN_IDENTITY 环境覆盖或导出身份。" >&2
    exit 1
fi

# 全新临时目录（本次构建专用，含 module-cache）
mkdir -p "$ROOT/build"
BUILD_DIR="$(mktemp -d "$ROOT/build/release-XXXXXXXX")"
MODULE_CACHE="$BUILD_DIR/module-cache"
APP_DIR="$BUILD_DIR/帮我分析-v${APP_VERSION}.app"
mkdir -p "$MODULE_CACHE"

# 收集全部 swift 源文件；find 结果写入临时文件以防进程替换掩盖失败
SRC_LIST="$BUILD_DIR/sources.txt"
: > "$SRC_LIST"
for dir in "${SRC_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        find "$dir" -type f -name '*.swift' -print0 >> "$SRC_LIST"
    else
        echo "错误：缺失源码目录 $dir" >&2
        exit 1
    fi
done

SOURCES=()
while IFS= read -r -d '' f; do
    SOURCES+=("$f")
done < "$SRC_LIST"
if [[ ${#SOURCES[@]} -eq 0 ]]; then
    echo "错误：未找到任何源文件。" >&2
    exit 1
fi

echo "==> swiftc 原生构建（$APP_VERSION ($BUILD_NUM)）"
mkdir -p "$APP_DIR/Contents/MacOS"
swiftc -parse-as-library -swift-version 6 -O \
    -whole-module-optimization \
    -target "$TARGET" \
    -module-cache-path "$MODULE_CACHE" \
    -o "$APP_DIR/Contents/MacOS/$BINARY_NAME" \
    "${SOURCES[@]}"

echo "==> 构建本地分人引擎（与 make_app.sh 同一装配来源；15 号计划 F15）"
ENGINE_NAME="bangwo-local-diarization"
ENGINE_SRC="$ROOT/Helpers/LocalDiarization"
BWFX_ENGINE_RPATH="@executable_path/../Frameworks" \
    BWFX_ENGINE_OUT="$ROOT/build/$ENGINE_NAME" \
    bash "$ENGINE_SRC/build.sh"

echo "==> 组装 .app"
mkdir -p "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
cp "$ICON" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ROOT/build/$ENGINE_NAME" "$APP_DIR/Contents/MacOS/$ENGINE_NAME"
cp "$ROOT/build/engine-deps/lib/libsherpa-onnx-c-api.dylib" "$APP_DIR/Contents/Frameworks/" 2>/dev/null || \
    { echo "错误：缺少引擎共享库（build/engine-deps/lib）" >&2; exit 1; }
cp "$ROOT/build/engine-deps/lib/libonnxruntime.dylib" "$APP_DIR/Contents/Frameworks/"

echo "==> 稳定身份签名：$SIGNING_IDENTITY"
# 嵌套代码先签（与 make_app.sh 同序），外层再带 entitlements 签名
codesign --force --sign "$SIGNING_IDENTITY" \
    "$APP_DIR/Contents/Frameworks/libsherpa-onnx-c-api.dylib" \
    "$APP_DIR/Contents/Frameworks/libonnxruntime.dylib"
codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR/Contents/MacOS/$ENGINE_NAME"
codesign --force --sign "$SIGNING_IDENTITY" \
    --entitlements "$ENTITLEMENTS" "$APP_DIR"

echo "==> 签名校验"
codesign --verify --deep --strict "$APP_DIR"
codesign -dv --verbose=4 "$APP_DIR" > "$BUILD_DIR/signature.txt" 2>&1
cat "$BUILD_DIR/signature.txt"
if ! grep -Fxq "Authority=$SIGNING_IDENTITY" "$BUILD_DIR/signature.txt"; then
    echo "错误：签名身份不符合预期。此版本校验失败，请勿交付。" >&2
    exit 1
fi

# 构建清单（15 号计划 H.4）：精确源码 SHA 与产物 hash，不从文件时间猜构建来源
{
    echo "app_path=$APP_DIR"
    echo "version=${APP_VERSION}"
    echo "build=${BUILD_NUM}"
    echo "config=native-swiftc-release"
    echo "git_head=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "git_dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    echo "binary_sha256=$(shasum -a 256 "$APP_DIR/Contents/MacOS/${BINARY_NAME}" | awk '{print $1}')"
    echo "engine_sha256=$(shasum -a 256 "$APP_DIR/Contents/MacOS/$ENGINE_NAME" | awk '{print $1}')"
    echo "dylib_sha256_libsherpa=$(shasum -a 256 "$APP_DIR/Contents/Frameworks/libsherpa-onnx-c-api.dylib" | awk '{print $1}')"
    echo "dylib_sha256_onnxruntime=$(shasum -a 256 "$APP_DIR/Contents/Frameworks/libonnxruntime.dylib" | awk '{print $1}')"
    echo "signing_identity=$SIGNING_IDENTITY"
} > "$BUILD_DIR/构建清单-v${APP_VERSION}.txt"
echo "==> 构建清单：$BUILD_DIR/构建清单-v${APP_VERSION}.txt"
echo "完整 App 路径：$APP_DIR"
echo "版本：${APP_VERSION}（build ${BUILD_NUM}）"
