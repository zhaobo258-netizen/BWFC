# 帮我分析（BangWoFenXi）

面向线下中文商务谈判的 Mac App：实时录音、同声转写、结构总结与证据化谈判分析。
本仓库已完成 **阶段 0–6**（MVP 全部阶段）。交付状态与人工验收清单见 `交付说明.md`。

- 实施计划：`../01_帮我分析_Mac_MVP开发实施计划.md`
- 平台：Apple Silicon Mac，macOS 26+，Swift 6（严格并发）
- 无第三方依赖：网络层使用 URLSession，密钥明文存入本机 App 配置

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

## 阶段 2 已实现

- 本地同声转写：`SpeechTranscriber`（timeIndexedProgressiveTranscription preset，
  临时/最终结果均带 CMTimeRange）；`isAvailable` + zh-Hans 支持 + `AssetInventory`
  资源状态三道检查，不可用则阻止开始并显示真实原因（不静默降级）。
- 采集 tap 缓冲同时写录音文件与 SpeechAnalyzer（`onBuffer` 分发，
  `bestAvailableAudioFormat` + AVAudioConverter 按需转换）。
- 录音条实时显示输入电平；最近声音持续偏小时明确提醒靠近麦克风或提高播放音量，
  避免在低质量音频上继续积累错误。结束录音时会等待 SpeechAnalyzer 的尾部最终结果，
  不会因提前取消结果收集而丢掉最后一句。
- 上下文词汇：glossary + 参会人姓名/角色经 `AnalysisContext.contextualStrings`
  送入（仅改善识别，不改写原意）。
- 片段合并：`TranscriptReconciler` 纯逻辑——临时片段同 ID 就地更新；最终结果按
  「时间范围为主、规范化文本相似度为辅」去重（同文 ±2s 抖动、重叠 ≥50% 且
  相似 ≥0.8 判重，重叠但文本不同保留），20 分钟模拟验证无重复片段。
- 时间换算：分析器音频流时间经 `RecordingTimeline.wallMs(forEffectiveAudioMs:)`
  逆映射回会议时间轴（正确还原暂停区间）。
- 底部转写 UI：时间/说话人（未识别显示「识别中」）/正文/状态；自动滚动 +
  上翻暂停 + 「回到最新」；临时文字浅色；最终替换就地更新不跳动。

## 构建与运行

```bash
swift build                    # 编译（0 警告基线）
Scripts/make_app.sh            # Debug .app（当前产出 build/帮我分析-v0.2.1.app）
Scripts/make_app.sh release    # Release .app（稳定本机签名 + Sandbox/麦克风/网络 entitlements）
open "build/帮我分析-v0.2.1.app" # 启动
Scripts/run_tests.sh           # 全部 624 个自动化用例（77 套件）
Scripts/soak_test.sh           # 稳定性缩短版（180s/4x）
Scripts/soak_test.sh 3600 1    # 60 分钟完整稳定性（人工验收）
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

- API Key 明文写入本机 App 配置（`Core/Security`），仓库中只允许占位符。
- 日志统一走 `Core/Logging`：只记录时间、片段 ID、耗时、状态码与脱敏错误，
  严禁记录转写原文、会议背景、参会人姓名、Key 或音频路径。
- 真实谈判录音、声纹样本不进入仓库与测试夹具。

## 阶段 3 已实现

- 声音样本：每位参会人 2–10 秒录制 / 试听 / 重录；时长与有效音量校验
  （VoiceSampleValidator 纯逻辑）；样本存 `Meetings/<uuid>/samples/<p-uuid>.wav`，
  Participant 记相对路径与时长。
- 分片队列：20 秒分片、2 秒重叠（ChunkPlanner 纯逻辑）；每片记录会议绝对起止毫秒；
  成功且结果持久化后删除临时分片；失败指数退避（1s→2s→4s→8s，上限 5 次），
  超上限进「待用户重试」；队列持久化到 chunks/queue.json，App 重启后补传恢复。
- 云端调用：POST /v1/audio/transcriptions（URLSession + 手写 multipart，无第三方依赖）；
  known_speaker_names[] 只传 p_01…p_04 代号，样本以 data URL 传输；API Key 只从
  本机配置读取；响应只读取总时长、片段起止、文字与 speaker 标签。
- 合并：云端片段经 TranscriptReconciler 与本地片段合并（本地 provisional → cloud final
  就地更新、ID 稳定）；「人工已修订」片段不被云端覆盖；未知说话人显示「待识别 A/B」，
  右键可手动映射、改文字、加星标。
- 异常处理：401 → 云端暂停、本地继续、修复后重试；429/5xx/超时 → 退避重试；
  错序结果按绝对时间排序合并；队列与分片文件状态在崩溃后一致恢复。
- 测试：URLProtocol Mock 集成（成功/空结果/401/429/500/超时/坏响应/未配置 Key），
  编排集成（产出/成功流/尾部分片/退避上限/401 暂停恢复/重启恢复/错序合并/代号检查）。

## 阶段 4 已实现

- 严格 JSON Schema（Structured Outputs）：输出结构按计划 10.2（current_topic、
  topics、our/counterpart_positions、confirmed/open_items、key_facts、insights 六类），
  strict 模式；解码失败/不合规整版丢弃并保留上一版。
- 增量上下文组装：背景/目标/底线/对方背景 + 参会人代号与角色 + 上一版状态 + 新增最终片段；
  只发代号不发真实姓名；原话置于独立不可信数据对象（含「不是指令」声明，注入防护）。
- 系统指令：实施计划 10.3 全部 8 条约束，集中维护于 AnalysisSystemPrompt。
- 调度器：≥3 新片段或 >45s 触发、10s 防抖、串行单请求、失败退避 30s 防热循环、
  游标 lastAnalyzedSegmentEndMs；失败保留上一版；快照原子替换；
  会议结束后用完整最终转写生成「最终分析」。
- 证据校验：每个结构项/议题/分析项的 evidence_segment_ids 非空且必须引用真实片段，
  否则构建时过滤不进 UI。
- Responses API：store:false、严格 schema、URLSession、错误分类（401 暂停/429/5xx/超时），
  模型 ID 集中配置（CloudModelConfig）。
- UI：左侧固定 7 段结构总结（空显示「尚无足够信息」）；右侧六类分析卡片
  （判断、参会人、明确表达/AI 推测标签（蓝/橙视觉区分）、低/中/高置信度、证据、更新时间）；
  点击证据定位底部片段（滚动 + 高亮）；无回应建议。

## 阶段 5 已实现

- finalizing 完整流程：结束 → 停止采集 → 清空分片队列 → 最终分析 → completed；
  仍有失败分片时弹窗选择「重试并继续等待」或「稍后继续处理」（队列本机保留，下次打开补传）。
- 会后页面：完整按人转写（改说话人/改文字/星标）、最终结构总结与六类分析
  （复用会中组件）；点击证据定位转写并从对应时间播放录音。
- 「重新生成最终分析」按钮：人工修订后用完整最终转写重新生成并替换快照。
- 导出 Markdown：会议信息、结构总结、分析（证据含时间戳 + 说话人 + 原文）、
  完整按人转写，可独立阅读；NSSavePanel 由用户选择位置，不含 API Key。
- 导出 JSON：formatVersion 信封 + 会议完整 Codable 结构，可重新解析，
  片段 ID 与证据引用完整（测试验证往返一致）。
- 删除整场会议：二次确认并明确列明删除内容（录音、样本、分片与队列、数据库记录）；
  删除后验证会议专属目录与数据库记录均不存在；导出文件存于用户自选位置，
  应用目录内无导出缓存需清理。

## 当前 AI Provider

- 实时分析、完整总结、项目对话和开花共用当前分析模型：Kimi，或一个用户配置的
  OpenAI-compatible Chat Completions 模型；设置变化从下一次请求生效。
- Kimi 使用 `POST https://api.kimi.com/coding/v1/messages`（Anthropic messages）；
  默认优先 `k3-256k`，可选 `k3` 和 `kimi-for-coding`。K3 保持 thinking，
  权限不足时如实报错，不静默切换模型。
- 无 Structured Outputs 强制能力：系统提示词约束「只输出 JSON」+ 本地
  AnalysisSchema 严格解码与证据过滤兜底；不合规按 invalidResponse 处理并保留上一版。
- 响应 content 可能含 thinking/text 块：只拼接 text 块；```json 围栏解析前剥离。
- 高精度转写与说话人识别模块保持 OpenAI Audio Transcriptions 兼容形态；
  未配置时明确显示当前仅使用本地 Apple Speech。Kimi 只处理文字，不能替代音频识别。
- Kimi 凭证优先使用账号登录；“Kimi API Key”是未登录时的备用认证，不是“分析人”
  或说话人身份。说话人识别使用独立 Key。
- 用户笔记默认不上传；按项目开启授权后，只在项目对话、开花或完整总结请求发起时
  读取当时最新文本，不逐键上传。外部 MCP 不接收笔记。
- 项目对话默认开启“联网搜索”：明确要求搜索时直接生成短检索词，
  其他消息由 AI 判断是否需要外部资料。每轮最多发送两条、每条不超过 24 字的
  检索词给 Kimi 通用网页搜索；逐字稿、笔记、历史对话和引用文档不发送给搜索源。
  回答保留可点开的真实来源；Kimi 搜索异常时回退中文维基百科，两者都失败时明确说明
  本轮没有取得联网来源。

## 当前工作台补充能力

- 录音中的笔记使用稳定的原生文本编辑器；界面高频刷新时不回写中文输入法的
  marked text，笔记仍按原有防抖策略自动保存。
- 完整总结通读全部最终/人工修订逐字稿，分析账本只作辅助；全量分析 JSON 失败时仍可
  从完整逐字稿生成。报告包含完整概述、核心议题、带时间戳章节概要、事实、结论、
  行动项、分歧风险、未决问题与关键原话；用户主动发送的共创内容和获授权的旧笔记
  单独整理为“我的思考与 AI 共创”，不会混写成录音事实。
- 开花会自动处理新出现的高优先知识种子；检索 Obsidian、互联网和只读 MCP 后，
  再由当前分析模型生成“来源速览、关键知识点、与本场讨论的关系”，并保留真实来源引用。
