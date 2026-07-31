#!/bin/bash
# M4 损坏恢复演练：在临时目录的 projects.json **副本** 上走完
# 「损坏 → 备份 → 空库 → 人工修复 → 恢复」全流程。
#
# 安全约束：只读取真实容器目录一次用于复制；真实文件全程不写、不改名、不删除。
# 演练结束校验真实文件 SHA-256 未变。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REAL_DIR="$HOME/Library/Containers/com.zhaobo.BangWoFenXi/Data/Library/Application Support/BangWoFenXi"
REAL_FILE="$REAL_DIR/projects.json"
OUT_DIR="$ROOT/build"
SRC_DIR="$OUT_DIR/drill-src"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/BangWoFenXiDrill.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

if [ -f "$REAL_FILE" ]; then
    BEFORE="$(shasum -a 256 "$REAL_FILE" | awk '{print $1}')"
    cp "$REAL_FILE" "$WORK_DIR/projects.json"
    echo "==> 使用真实 projects.json 的副本（只读复制）"
else
    echo "==> 真实 projects.json 不存在，改用合成样本"
    printf '[{"schemaVersion":2,"id":"%s","title":"演练样本","sourceType":"liveRecording","scenarioWasUserSelected":false,"status":"ready","createdAt":"2026-01-01T00:00:00Z","lastActivityAt":"2026-01-01T00:00:00Z","durationMs":0,"pauseIntervals":[],"note":{"markdown":"","updatedAt":"2026-01-01T00:00:00Z"},"processingJobs":[],"archive":{}}]' \
        "$(uuidgen)" > "$WORK_DIR/projects.json"
    BEFORE=""
fi

mkdir -p "$OUT_DIR"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
find App Models Features Core -name "*.swift" ! -name "BangWoFenXiApp.swift" | while read -r f; do
    cp "$f" "$SRC_DIR/"
done
cp "Scripts/Drill/main.swift" "$SRC_DIR/"

echo "==> 编译演练器"
swiftc -O -module-name BangWoFenXiDrill -o "$OUT_DIR/BangWoFenXiDrill" "$SRC_DIR"/*.swift

echo "==> 运行演练（工作目录：${WORK_DIR}）"
set +e
"$OUT_DIR/BangWoFenXiDrill" "$WORK_DIR"
DRILL_STATUS=$?
set -e

if [ -n "$BEFORE" ]; then
    AFTER="$(shasum -a 256 "$REAL_FILE" | awk '{print $1}')"
    if [ "$BEFORE" = "$AFTER" ]; then
        echo "==> 真实 projects.json SHA-256 未变（演练全程未写真实数据）"
    else
        echo "REAL DATA CHANGED — 真实 projects.json 哈希变了，立即人工检查"
        exit 1
    fi
    LEFTOVER="$(ls "$REAL_DIR" | grep -c '^projects.corrupt-' || true)"
    echo "==> 真实目录残留损坏备份文件数：${LEFTOVER}（应为 0）"
fi

exit $DRILL_STATUS
