# 帮我分析（BangWoFenXi）

面向线下中文商务谈判的 Mac App：实时录音、同声转写、结构总结与证据化谈判分析。
本仓库已完成 **阶段 0（工程骨架）** 与 **阶段 1（会前准备与本地录音）**。

- 实施计划：`../01_帮我分析_Mac_MVP开发实施计划.md`
- 平台：Apple Silicon Mac，macOS 26+，Swift 6（严格并发）
- 无第三方依赖：网络层使用 URLSession，密钥仅存 Keychain

## 阶段 1 已实现

- 会前表单：基本信息（背景/目标/底线/对方背景）、专业词汇增删、参会人 CRUD
  （姓名/阵营/角色/颜色，最多 4 名上限与提示，云端代号 p_01…p_04 自动分配）。
- 麦克风：输入设备枚举与选择、5 秒电平测试（纯逻辑评估器可单测）。
- 录音：开始/暂停/继续/结束，全程走会议状态机；PCM .caf 写入
  `Application Support/BangWoFenXi/Meetings/<uuid>/recording.caf`，数据库只存相对路径；
  暂停区间不写文件并记录时间区间；麦克风拔出自动暂停并提示换新设备。
- 异常退出恢复：启动时发现 recording/paused/finalizing 会议，弹窗提示保留录音，
  可标记为已结束或打开查看。
- 会后回放：AVAudioPlayer 播放/暂停/进度拖动与暂停区间标注。
- 录音核心逻辑（时间线换算、路径约定、编排服务、电平评估）均为可单测纯逻辑，
  AVAudioEngine 只做薄壳，硬件经 `AudioCaptureServicing` 协议隔离。

## 构建与运行

```bash
swift build                 # 编译（debug）
Scripts/make_app.sh         # 产出 build/BangWoFenXi.app（ad-hoc 签名 + Sandbox/麦克风/网络 entitlements）
open build/BangWoFenXi.app  # 启动
Scripts/make_app.sh release # release 构建
```

## 测试

```bash
Scripts/run_tests.sh        # 真实执行全部 swift-testing 用例（当前环境推荐）
swift test                  # 可完成构建；本机执行阶段静默失效，见下文「已知环境限制」
```

## 已知环境限制（本机无 Xcode，仅 Command Line Tools）

1. **SwiftData 宏不可用**：CLT 工具链不含 `SwiftDataMacros` 编译器插件（仅随 Xcode 分发），
   `@Model` 无法展开。阶段 0 的模型先以纯 Swift 类实现（字段与实施计划第 9 节完全一致），
   持久化经 `MeetingStoring` 协议隔离，当前实现为 `JSONMeetingStore`
   （Application Support 内原子写入）。安装 Xcode 后：模型加回 `@Model` 宏与关系声明，
   并提供 SwiftData 版 `MeetingStoring` 实现即可无缝切换。
2. **`swift test` 执行阶段静默失效**：CLT 的 `swiftpm-testing-helper` 对任何包都只构建、
   不执行测试（已用最小探针包复现）。在 Xcode 安装前，请使用 `Scripts/run_tests.sh` 执行测试。
   测试 target 在 Package.swift 中显式指向 CLT 自带的 `Testing.framework`（编译 `-F` + 运行 `rpath`）。
3. **XCTest 不可用**：CLT 不含 XCTest，测试统一使用 swift-testing。

## 安全基线（实施计划第 0、12 节）

- API Key 只进 Keychain（`Core/Security`），仓库中只允许占位符。
- 日志统一走 `Core/Logging`：只记录时间、片段 ID、耗时、状态码与脱敏错误，
  严禁记录转写原文、会议背景、参会人姓名、Key 或音频路径。
- 真实谈判录音、声纹样本不进入仓库与测试夹具。
