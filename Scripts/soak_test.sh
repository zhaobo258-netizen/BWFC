#!/bin/bash
# 《帮我分析》无人值守稳定性测试（阶段 6）。
# 编译 Soak 运行器（复用工程自身管线类型）并运行合成音频驱动的长时间录音校验。
#
# 用法：
#   Scripts/soak_test.sh              # 缩短版：180 秒音频，4 倍速（约 1 分钟墙钟）
#   Scripts/soak_test.sh 3600 1       # 完整版：60 分钟音频，实时速度（人工验收用）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DURATION="${1:-180}"
RATE="${2:-4}"
OUT_DIR="$ROOT/build"
WORK_DIR="$OUT_DIR/soak-src"

mkdir -p "$OUT_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# 复用工程源码（排除 @main 入口），加 Soak 入口
find App Models Features Core -name "*.swift" ! -name "BangWoFenXiApp.swift" | while read -r f; do
    cp "$f" "$WORK_DIR/"
done
cp "Scripts/Soak/main.swift" "$WORK_DIR/"

echo "==> 编译 Soak 运行器"
# shellcheck disable=SC2046
swiftc -O \
    -module-name BangWoFenXiSoak \
    -o "$OUT_DIR/BangWoFenXiSoak" \
    "$WORK_DIR"/*.swift

echo "==> 运行：音频 ${DURATION}s，${RATE}x 速率"
"$OUT_DIR/BangWoFenXiSoak" "$DURATION" "$RATE"
