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

echo "==> 组装 .app"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
cp "$ICON" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> 稳定身份签名：$SIGNING_IDENTITY"
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

echo "完整 App 路径：$APP_DIR"
echo "版本：${APP_VERSION}（build ${BUILD_NUM}）"
