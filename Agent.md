# Agent.md — 给后续维护本项目的 AI 协作者

> 你是《帮我分析》Mac App 的维护者。这是一个面向线下中文商务谈判的 macOS SwiftUI App：本地录音 + Apple Speech 实时转写 + 云端说话人识别 + Kimi 网关谈判分析。
> 动手前请读完本文件；产品边界以 `../01_帮我分析_Mac_MVP开发实施计划.md` 为准；历史排查过程见 `开发日志.md`。

## 1. 环境现实（重要）

- 本机**没有 Xcode**，只有 Command Line Tools（Swift 6.3.2，macOS 26.5.2，arm64）。`xcodebuild` 不可用。
- 因此不是 Xcode 工程，而是 **SPM 可执行包 + 自制 .app 打包脚本**。不要尝试 `xcodebuild`，不要引入 xcodegen/tuist 依赖。
- CLT 缺陷两条（已绕行，勿"修复"回退）：
  1. 无 `SwiftDataMacros` 宏 → 模型是纯 Swift 类，持久化走 `MeetingStoring` 协议 + JSON 原子写入。装 Xcode 后可加回 `@Model` + SwiftData 实现，字段零改动。
  2. `swift test` 静默不执行 → **必须用 `Scripts/run_tests.sh` 跑测试**（它把源码+测试编入独立执行器真实执行）。

## 2. 常用命令

```bash
cd /Users/zhaobo/系统软件开发/帮我分析-同声翻译/帮我分析
swift build                 # 编译，要求 0 警告（Swift 6 严格并发）
Scripts/run_tests.sh        # 全部测试（当前 224 例，必须全绿）
Scripts/make_app.sh         # 产出 build/BangWoFenXi.app（ad-hoc 签名 + entitlements）
Scripts/soak_test.sh 3600 1 # 60 分钟录音稳定性（尚未完整跑过）
```

安装到本机（用户实机测试的标准动作）：

```bash
pkill -x BangWoFenXi; sleep 2
rm -rf ~/Applications/BangWoFenXi.app
cp -R build/BangWoFenXi.app ~/Applications/
xattr -dr com.apple.quarantine ~/Applications/BangWoFenXi.app
open ~/Applications/BangWoFenXi.app
```

调试开关：`defaults write com.zhaobo.BangWoFenXi bwfxDebugCounters -bool YES` 后界面底部显示 PerfCounters 计数条（发布/节流/计时器/面板求值），排查界面问题时务必打开。

## 3. 架构速览

```
App/        @main、AppEnvironment（协议注入全部服务）、AppRouter
Models/     Meeting（含状态机）、Participant、TranscriptSegment、AnalysisSnapshot、Insight、TopicState
Features/   MeetingList / MeetingSetup / LiveMeeting / MeetingReview / Settings
Core/
  Audio/        AVAudioEngine 采集、录音编排、回放、暂停时间轴
  Transcription/ SpeechTranscriber 封装、TranscriptReconciler（合并去重核心纯逻辑）
  Diarization/  20s 分片、上传队列（持久化+退避）、OpenAI 兼容 diarize、SpeakerMapper
  Analysis/     KimiAnalysisService、输入组装（不可信包裹）、Schema 校验、触发器
  Persistence/  MeetingStoring 协议 + JSON 实现、会议专属目录（数据库只存相对路径）
  Security/     KeychainService、CloudAPIKeyStore（按 provider 分条目）
  Logging/      OSLog + 脱敏；Export/ Markdown/JSON
```

关键约定：

- UI 只依赖协议（AudioCaptureServicing、LocalTranscriptionServicing、DiarizationServicing、NegotiationAnalysisServicing、MeetingStoring…），测试用 Mock 注入。
- 模型 ID、网关地址、超时、max_tokens 全部集中在 `Core/Analysis/CloudModelConfig.swift`，禁止散落。
- 所有耗时纯逻辑（分片规划、退避、合并去重、触发器、时间轴换算）都是可单测的值类型；AVFoundation/Speech 只做薄壳。

## 4. 云端配置现状

| 用途 | Provider | 端点 | Keychain account |
|---|---|---|---|
| 谈判文字分析 | Kimi | `https://agent-gw.kimi.com/coding/v1/messages`（Anthropic 格式，模型 `kimi-for-coding`，`thinking: disabled`，max_tokens 16384，超时 240s） | `kimi` |
| 说话人识别 | OpenAI 兼容 | `POST /v1/audio/transcriptions`，`gpt-4o-transcribe-diarize` | `diarization`（当前**未配置**，灰态零请求） |

- 两个 Key **互不外借**；某 provider 401 只暂停它自己。旧 `openai` 条目会在启动时自动迁移到 `kimi`。
- Kimi 无音频分人接口——这是已确认的能力缺口，不是 bug。接新分人 provider 时实现 `DiarizationServicing` 协议即可。
- Kimi 网关无 JSON Schema 强制能力 → 系统提示词约束 + 本地 `AnalysisSchema` 严格解码 + 证据存在性过滤兜底；不合规输出按 `invalidResponse` 丢弃并保留上一版。
- 真实延迟参考：10 分钟会议上下文，单次分析约 95 秒。不要在调度层假设 60 秒内返回。

## 5. 血泪教训（不要再踩）

1. **@Observable 存储属性上禁止 `mutating` 方法被渲染路径调用**。Swift 会把"读"当"写"广播变更 → 视图自激死循环（2026-07-21 三轮卡死的实锤根因，`SpeakerMapper.resolve`）。读路径必须是纯函数；测试已用 `let` 绑定调用做编译级锁死。
2. **先仪表化再猜因**。`PerfCounters` + `sample <pid>` 是排查 SwiftUI 卡死的两件套；界面卡死但计数不动 = 视图自激；计数狂涨 = 发布风暴，两者修法完全不同。
3. **Anthropic messages 的 max_tokens 包含 thinking**。预算不足时 text 被截断成非法 JSON；已关闭 thinking（`"thinking": {"type": "disabled"}`，网关确认支持且更快）。
4. **os_log 默认全 `<private>`**。脱敏后的安全字段（错误类别、HTTP 状态码、耗时）必须用 `AppLog.logError/logWarning`（privacy public）记录，否则实机无法诊断；但原文、姓名、Key、音频路径**永远**不进日志。
5. **AVAudioFile.read 会短读**（如 536/676 帧），读取必须循环到满；`URLSession` 会把 `httpBody` 转 `httpBodyStream`，测试两种形态兼容。
6. **URLProtocol Mock 与 swift-testing 并行冲突**：用套件内 `.serialized` + 套件专属存储。
7. **deinit 里别释放捕获 self 的 handler 闭包**（释放环）；handler 一律静态化。

## 6. 产品红线（来自计划书，违者返工）

- 不把"AI 推测"写成"事实"；任何分析项必须带真实存在的证据片段 ID，否则不进 UI。
- API Key 只进 Keychain；真实谈判录音、声纹样本、客户资料不进仓库、不进测试夹具、不进日志。
- 云端模型/语言资源不可用时，停止对应模块并显示真实错误，**不静默切换假实现**。
- 不做：翻译、回应建议/话术、测谎、情绪/人格判断、账号体系、移动端/Windows、App Store 外发。
- 内部原型口径：不签名公证、不外发；汇报分清"本地已做/本地已验证/远端已生效/客户可交付/真实使用已验证"。

## 7. 当前未决事项（接手先看）

1. 长会议（10 分钟+）分析持续多版更新的实机复核（第六版 `29ba298` 修复后待用户回报）。
2. 说话人识别 provider 决策：OpenAI Key / 讯飞 / 火山 / 维持手动标注。
3. 60 分钟完整 soak 未跑；导出 Markdown/JSON 的实机操作未验。
4. 装 Xcode 后的回迁项：SwiftData 宏、`swift test`。
5. 分析延迟 1.5–2 分钟/版 vs 计划 60 秒目标的偏差，需记入交付说明.md「未达指标」。
