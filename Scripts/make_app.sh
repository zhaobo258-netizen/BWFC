#!/bin/bash
# 《帮我分析》自制 .app 打包脚本（无 Xcode 环境：SPM 构建 + 手工组装 bundle + ad-hoc 签名）
# 用法：Scripts/make_app.sh [debug|release]   默认 debug
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
BINARY_NAME="BangWoFenXi"
APP_DIR="$ROOT/build/${BINARY_NAME}.app"

cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/${BINARY_NAME}"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "错误：找不到构建产物 $BIN_PATH" >&2
    exit 1
fi

echo "==> 组装 ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${BINARY_NAME}"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# SPM 资源 bundle（本阶段暂无资源；存在则一并拷入）
RESOURCE_BUNDLE="$(swift build -c "$CONFIG" --show-bin-path)/${BINARY_NAME}_${BINARY_NAME}.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
fi

echo "==> ad-hoc 签名（含 Sandbox / 麦克风 / 出站网络 entitlements）"
codesign --force --sign - --entitlements "$ROOT/Entitlements.plist" "$APP_DIR"

echo "==> 签名校验"
codesign -dv "$APP_DIR" 2>&1 | sed 's/^/    /'

echo "==> 完成：$APP_DIR"
echo "    启动：open \"$APP_DIR\""
