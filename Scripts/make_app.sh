#!/bin/bash
# 《帮我分析》自制 .app 打包脚本（无 Xcode 环境：SPM 构建 + 手工组装 bundle + 稳定本机签名）
# 用法：Scripts/make_app.sh [debug|release]   默认 debug
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
BINARY_NAME="BangWoFenXi"
INFO_PLIST="$ROOT/Resources/Info.plist"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "错误：Info.plist 中的版本号无效：$APP_VERSION" >&2
    exit 1
fi
APP_DIR="$ROOT/build/帮我分析-v${APP_VERSION}.app"
LOCAL_SIGNING_IDENTITY="BangWoFenXi Local Code Signing"
SIGNING_IDENTITY="${BWFX_CODESIGN_IDENTITY:-}"

cd "$ROOT"

if [[ -z "$SIGNING_IDENTITY" ]]; then
    if security find-identity -v -p codesigning \
        | grep -Fq "\"$LOCAL_SIGNING_IDENTITY\""; then
        SIGNING_IDENTITY="$LOCAL_SIGNING_IDENTITY"
    elif [[ "${BWFX_ALLOW_ADHOC:-0}" == "1" ]]; then
        SIGNING_IDENTITY="-"
    else
        echo "错误：未找到稳定签名身份 \"$LOCAL_SIGNING_IDENTITY\"。" >&2
        echo "安装包禁止使用 ad-hoc；仅临时测试可显式设置 BWFX_ALLOW_ADHOC=1。" >&2
        exit 1
    fi
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/${BINARY_NAME}"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "错误：找不到构建产物 $BIN_PATH" >&2
    exit 1
fi

echo "==> 构建本地分人引擎（sherpa-onnx 独立进程，13/14 号文档 20260913）"
ENGINE_NAME="bangwo-local-diarization"
ENGINE_SRC="$ROOT/Helpers/LocalDiarization"
# 打包形态：引擎与主程序同目录（Contents/MacOS），dylib 在 Contents/Frameworks，
# 引擎以 @executable_path/../Frameworks 解析依赖；沙箱下子进程继承 App 沙箱，不依赖环境变量。
BWFX_ENGINE_RPATH="@executable_path/../Frameworks" \
    BWFX_ENGINE_OUT="$ROOT/build/$ENGINE_NAME" \
    bash "$ENGINE_SRC/build.sh"

echo "==> 组装 ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${BINARY_NAME}"
cp "$ROOT/build/$ENGINE_NAME" "$APP_DIR/Contents/MacOS/$ENGINE_NAME"
cp "$ROOT/build/engine-deps/lib/libsherpa-onnx-c-api.dylib" "$APP_DIR/Contents/Frameworks/" 2>/dev/null || \
    { echo "错误：缺少引擎共享库（build/engine-deps/lib），请先跑一次引擎构建" >&2; exit 1; }
cp "$ROOT/build/engine-deps/lib/libonnxruntime.dylib" "$APP_DIR/Contents/Frameworks/"
cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# SPM 资源 bundle（本阶段暂无资源；存在则一并拷入）
RESOURCE_BUNDLE="$(swift build -c "$CONFIG" --show-bin-path)/${BINARY_NAME}_${BINARY_NAME}.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "==> ad-hoc 签名（仅临时测试；禁止覆盖已安装 App）"
else
    echo "==> 稳定身份签名：$SIGNING_IDENTITY"
fi
# 嵌套代码先签（稳定身份），外层再带 entitlements 签名
codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR/Contents/Frameworks/libsherpa-onnx-c-api.dylib" "$APP_DIR/Contents/Frameworks/libonnxruntime.dylib"
codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR/Contents/MacOS/$ENGINE_NAME"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ROOT/Entitlements.plist" "$APP_DIR"

echo "==> 签名校验"
codesign -dv "$APP_DIR" 2>&1 | sed 's/^/    /'

echo "==> 完成：$APP_DIR"
echo "    启动：open \"$APP_DIR\""
