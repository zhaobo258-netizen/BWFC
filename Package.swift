// swift-tools-version: 6.2
// 《帮我分析》SPM 可执行包（无 Xcode 环境下的工程骨架，见实施计划第 7、8 节）
import PackageDescription

let package = Package(
    name: "BangWoFenXi",
    platforms: [
        // 最低系统 macOS 26（SpeechAnalyzer / SpeechTranscriber 需要）
        .macOS(.v26)
    ],
    targets: [
        // 主程序：SwiftUI App 生命周期在 SPM executable 中可正常运行
        .executableTarget(
            name: "BangWoFenXi",
            path: ".",
            exclude: [
                "BangWoFenXiTests",
                "Scripts",
                "Resources",
                "Entitlements.plist",
                "README.md",
                "交付说明.md",
                "Agent.md",
                "开发日志.md",
                // 打包与测试执行器的临时产物
                "build",
                "output"
            ],
            sources: [
                "App",
                "Models",
                "Features",
                "Core"
            ]
        ),
        // 单元测试（swift-testing）。
        // 无 Xcode 环境下 Testing.framework 不在默认搜索路径，
        // 显式指向 CLT 自带的框架目录（含编译 -F 与运行 rpath）。
        .testTarget(
            name: "BangWoFenXiTests",
            dependencies: ["BangWoFenXi"],
            path: "BangWoFenXiTests",
            swiftSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        )
    ]
)
