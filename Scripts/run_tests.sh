#!/bin/bash
# 《帮我分析》测试执行脚本（无 Xcode 环境专用）。
#
# 背景：本机 Command Line Tools 的 swiftpm-testing-helper 存在缺陷——
# `swift test` 能完成构建，但执行阶段静默退出、不运行任何测试
# （用最小探针包复现，与工程本身无关）。因此本脚本改用 swiftc 将
# 「应用源码（除 @main 入口）+ 测试套件 + 测试入口」编译为独立执行器，
# 直接调用 Testing.__swiftPMEntryPoint()，真实执行全部 swift-testing 用例。
#
# 注意：BangWoFenXiTests 测试 target 仍然保留；安装 Xcode 后 `swift test` 可正常工作。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CLT="/Library/Developer/CommandLineTools"
FW="$CLT/Library/Developer/Frameworks"
TESTLIB="$CLT/Library/Developer/usr/lib"
PLUGIN="$CLT/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
OUT_DIR="$ROOT/build"
WORK_DIR="$OUT_DIR/test-runner-src"

for path in "$FW/Testing.framework" "$PLUGIN"; do
    if [[ ! -e "$path" ]]; then
        echo "错误：缺少 $path（需要 CLT 自带的 swift-testing 组件）" >&2
        exit 1
    fi
done

mkdir -p "$OUT_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# 复制应用源码（排除 @main 入口，避免与测试入口冲突）
find App Models Features Core -name "*.swift" ! -name "BangWoFenXiApp.swift" | while read -r f; do
    cp "$f" "$WORK_DIR/"
done

# 复制测试源码，并去掉 @testable import（所有文件编入同一模块，无需 import 自身）
find BangWoFenXiTests -name "*.swift" | while read -r f; do
    sed 's/^@testable import BangWoFenXi$//' "$f" > "$WORK_DIR/$(basename "$f")"
done

# 生成测试入口
cat > "$WORK_DIR/TestsRunnerEntry.swift" <<'EOF'
import Testing

@main
struct TestsRunnerEntry {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
EOF

echo "==> 编译测试执行器"
# shellcheck disable=SC2046
swiftc -parse-as-library \
    -module-name BangWoFenXi \
    -F "$FW" \
    -load-plugin-library "$PLUGIN" \
    -framework Testing \
    -o "$OUT_DIR/BangWoFenXiTestsRunner" \
    "$WORK_DIR"/*.swift \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$TESTLIB"

echo "==> 执行测试"
"$OUT_DIR/BangWoFenXiTestsRunner" --testing-library swift-testing
