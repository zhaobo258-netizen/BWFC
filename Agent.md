# Agent.md — 给后续维护本项目的 AI 协作者

> 你是《帮我分析》Mac App 的维护者。这是一个“对话记录与理解”工具（知识花园版）：本地录音/音视频导入 + Apple Speech 本地转写 + 可配置分析模型 + 实时/完整总结 + 多知识来源开花 + 项目制自适应工作台。V1 谈判版功能全部保留兼容。
> 动手前请读完本文件；当前产品边界以 `../03_帮我分析_知识花园版_产品开发文档_20260722.md` 为准（V1 历史见 `../01_…MVP开发实施计划.md`）；历史排查过程见 `开发日志.md`。
> 阶段进度：A（V2 数据底座）✅ B（首页+自适应工作台）✅ C（音视频导入）✅ D（通用分析与场景模板）✅；E 已完成 Obsidian 权威存储迁移，但结构化项目页/block link 尚未落地；F 的开花与多知识来源已本地实现，真实外部 MCP 尚未验收。设置中心、完整总结和受限 AI 编排已完成本地代码、自动化和基础原生界面验收；真实模型、MCP、录音闭环仍待现场验收，G（稳定性交付）未完成。

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
Scripts/run_tests.sh        # 全部测试（当前 482 例 69 套件，必须全绿；BWFX_IT_MEDIA=1 加真实媒体探针）
Scripts/make_app.sh         # 产出带版本后缀的 build/帮我分析-v<版本>.app（稳定本机身份签名）
Scripts/soak_test.sh 3600 1 # 60 分钟录音稳定性（尚未完整跑过）
```

安装到本机（用户实机测试的标准动作）：

```bash
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD_APP="build/帮我分析-v${APP_VERSION}.app"
STAGING_APP="$TMPDIR/帮我分析-v${APP_VERSION}.staging.app"
INSTALLED_APP="$HOME/Applications/帮我分析-v${APP_VERSION}.app"
osascript -e 'tell application id "com.zhaobo.BangWoFenXi" to quit'
ditto "$BUILD_APP" "$STAGING_APP"
codesign --verify --deep --strict "$STAGING_APP"
mv "$STAGING_APP" "$INSTALLED_APP"
xattr -dr com.apple.quarantine "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"
open "$INSTALLED_APP"
```

覆盖安装前必须确认 `codesign -dv` 的 Authority 为稳定身份；不得把
`BWFX_ALLOW_ADHOC=1` 产物安装到用户正在使用的位置。

调试开关：`defaults write com.zhaobo.BangWoFenXi bwfxDebugCounters -bool YES` 后界面底部显示 PerfCounters 计数条（发布/节流/计时器/面板求值），排查界面问题时务必打开。

## 3. 架构速览

```
App/        @main、AppEnvironment（协议注入全部服务）、AppRouter（projectHome 默认）
Models/     V2：Project（权威模型，analysisSnapshots/legacy* 兼容字段）、Speaker、
            ConversationAnalysis（20 类单一枚举）、FinalReport（最近三版）、
            ProjectAIChat（背景纠正与项目问答，最多 60 条）、
            ProcessingJob、ArchiveState
            V1 保留：Meeting（运行时桥接用）、Participant、TranscriptSegment、AnalysisSnapshot、Insight
Features/   ProjectHome / ProjectWorkspace（宽/紧凑/窄屏 + 四个 AI 页签）/
            ProjectImport（含 finalReport Job）/ Settings（Root 弹层分类设置）；
            旧 MeetingList/LiveMeeting/MeetingReview 保留兼容
Core/
  Audio/        AVAudioEngine 采集、录音编排、回放、暂停时间轴
  Transcription/ SpeechTranscriber 封装、TranscriptReconciler（合并去重核心纯逻辑）
  Import/       AudioImportService（检查/提取）、FileTranscriptionRunner、ImportPlanner（Job 编排/续跑）
  Diarization/  20s 分片、上传队列（持久化+退避）、OpenAI 兼容 diarize、SpeakerMapper
  Analysis/     AIProviderRegistry（Kimi/OpenAI-compatible）、
                PromptRegistry、ProjectAIOrchestrator、FinalReportAgent、ProjectAIChatAgent，
                ConversationAnalysis{Prompt,Schema,InputAssembler,Service}
                V1：KimiAnalysisService（V1/V2 共用传输层 rawAnalysisText）、AnalysisSchema、触发器
  Knowledge/    KnowledgeBloomAgent、Obsidian/Internet Provider、多只读 Streamable HTTP MCP
  Persistence/  ProjectStore + MeetingStore（JSON 原子写）、ProjectMigration（V1→V2）、ProjectAssetRepair
  Security/     KeychainService、CloudAPIKeyStore（按 provider 分条目）、
                KimiOAuth（设备码登录客户端 + 凭证存储 + actor 凭证提供者，自动刷新）
  Logging/      OSLog + 脱敏；Export/ Markdown/JSON
```

关键约定：

- UI 只依赖协议（…Servicing、MeetingStoring、ProjectStoring），测试用 Mock 注入。
- **Project 是权威数据**；录音/转写链路复用只认 Meeting，经 `ProjectRuntimeSession` 纯函数桥接双向同步。V2 分析快照直接挂 Project，不经桥接。
- 导入流水线持久化为**字段级合并**（只写自己拥有的字段），不得整对象覆盖工作台并发编辑的笔记/标题。
- Kimi/分人固定模型、网关、超时集中在 `Core/Analysis/CloudModelConfig.swift`；用户自定义分析模型只通过 `AIProviderConfigurationStore` 管理，视图和业务代码不得直接读取 Endpoint 或 Key。
- 所有 AI 文本生成走 `AITextGenerationServing` / `AIProviderRegistry`；每次请求只读一次非敏感配置快照。凭证首次成功读取后只在当前 App 进程内复用，设置中的保存与删除必须同步更新或清除缓存；不得把“配置快照”扩大为每次请求都重新解密 Keychain。
- 启动迁移、录音、分析、完整总结、项目对话、开花、MCP 和测试等自动路径读取 Keychain 时，必须使用禁止交互的 `LAContext`。凭证因锁定或 ad-hoc 重签名无法读取时应立即失败并引导用户在设置中重连，绝不能唤起 SecurityAgent 密码框或阻塞本地录音/转写。
- 本机可安装包必须使用 `BangWoFenXi Local Code Signing` 或显式提供的稳定签名身份；ad-hoc 只允许临时测试，禁止覆盖用户正在使用的安装包。稳定签名身份只保存在本机登录 Keychain，不得导出或提交。
- `PromptRegistry` 是共享安全红线、场景规则、任务 Prompt、固定 JSON 合同与 Prompt Version 的唯一入口；普通设置页不开放原始 Prompt。
- 项目对话中只有用户消息会作为后续实时分析/开花的背景，不能充当逐字稿证据。仅当用户本轮明确给出错词和正词、模型返回包含该错词的真实片段 ID，且 App 在当前逐字稿再次核验通过时，才可复用全局纠错链路修改逐字稿并加入后续转写规则；普通讨论、背景补充或 AI 猜测不得改写原稿。
- 用户笔记默认不上云。`noteAIContextEnabled` 按项目授权后，项目对话、开花与完整总结在请求开始时读取编辑器最新文本（最多 20,000 字符）；不逐键上传，外部 MCP 仍只收最长 24 字短检索词。
- 完整总结以完整逐字稿和分析证据账本为事实来源；用户主动发送的项目对话、AI 反馈和获授权的旧笔记只能进入独立的 `collaborationSummary`，必须标明不是录音事实，也不得查询互联网/MCP。
- 所有耗时纯逻辑（分片规划、退避、合并去重、触发器、时间轴换算、Job 编排）都是可单测的值类型；AVFoundation/Speech 只做薄壳。

## 4. 云端配置现状

| 用途 | Provider | 端点 | 凭证 |
|---|---|---|---|
| 实时分析/完整总结/项目对话/开花 | Kimi | `https://api.kimi.com/coding/v1/messages`（Kimi Code Anthropic 协议；默认 `k3-256k`，可选 `k3` / `kimi-for-coding`；K3 保持 thinking，max_tokens 32768，超时 240s） | **Kimi 账号登录（OAuth，推荐）**：Keychain account `kimi-oauth`；后备静态 API Key：account `kimi` |
| 当前统一分析模型（可选） | OpenAI-compatible | 用户配置的 HTTPS 或 localhost Base URL + `/chat/completions`，模型 ID 由用户填写 | 独立 Keychain account `analysis-openai-compatible` |
| 说话人识别 | OpenAI 兼容 | `POST /v1/audio/transcriptions`，`gpt-4o-transcribe-diarize` | `diarization`（当前**未配置**，灰态零请求） |
| 外部知识来源 | 多个只读 Streamable HTTP MCP | 每个连接独立 Endpoint；先 `initialize` + `tools/list`，仅启用明确搜索/读取工具 | 每个连接独立 `knowledge-mcp.<UUID>`；旧单连接保留 `knowledge-mcp` |

- **Kimi OAuth（2026-07-24 落地，替代旧 agent-gw 通道）**：
  - 登录：设置页「登录 Kimi 账号」→ 设备码流程（`auth.kimi.com/api/oauth/device_authorization` → 浏览器确认 → 轮询 `api/oauth/token`）；client_id 是编译在官方 kimi CLI 里的公开常量（见 `CloudModelConfig`），非机密。
  - 刷新：access_token 900 秒过期；`KimiCredentialProvider`（actor + 共享 `refreshTask` 单飞）在剩余 <300s 时自动刷新。**refresh_token 每次刷新都轮换（实测）**：刷新成功必须立即持久化新值，否则下次刷新 invalid_grant 被迫重登；也因此 **App 与本机 kimi CLI 绝不能共用同一个 refresh_token**（各自独立登录，token 家族独立）。
  - 凭证优先级：OAuth（已登录）> 静态 Key（后备，未登录时才用）。刷新被拒 → `AnalysisAPIError.unauthorized`（凭证保留，设置页重新登录覆盖）；网络失败 → `.network`（可重试，不清凭证）。
  - 真实探针（07-24）：强制过期 → 真实刷新 → 真实 messages 请求全链路 200（5.8s）。旧 `agent-gw.kimi.com` 为遗留通道（新体系 token 全部 401），已弃用。
- Kimi、OpenAI-compatible 分析、分人和每个 MCP 凭证**互不外借**；某 Provider 401 只暂停它自己。稳定签名版本使用 Keychain service `com.zhaobo.BangWoFenXi.credentials.v2`；旧 ad-hoc service 原样保留但不自动解密，首次升级需在设置中重新连接一次，避免迁移旧 ACL 时再次弹系统密码框。
- Kimi 无音频分人接口——这是已确认的能力缺口，不是 bug。接新分人 provider 时实现 `DiarizationServicing` 协议即可。
- Kimi 网关无 JSON Schema 强制能力 → 系统提示词约束 + 本地严格解码（V1 `AnalysisSchema` / V2 `ConversationAnalysisSchema`）+ 证据存在性过滤兜底；不合规输出按 `invalidResponse` 丢弃并保留上一版。
- 默认优先 `k3-256k`：与 K3 同一模型能力、256K 上下文且额度消耗约为 `k3` 1M 的一半；K3 权限不足的 401 必须显示“凭证或模型权限”，禁止静默切到 K2.7/K2.6。K3 不发送禁用 thinking 参数，缺省推理强度为 high。
- OpenAI-compatible 走标准 Chat Completions、本地严格 JSON 解码且禁止 HTTP 重定向；连接测试只发送 `ping` 最小探测，不发送项目数据。
- MCP 只接受 HTTPS 或 localhost HTTP，禁止重定向；多候选只读工具必须由用户选择后再次测试。删除连接要同时删除独立 Token，但不得删除历史来源结果。
- 真实延迟参考：10 分钟会议上下文，单次分析约 75–95 秒。不要在调度层假设 60 秒内返回。

## 5. 血泪教训（不要再踩）

1. **@Observable 存储属性上禁止 `mutating` 方法被渲染路径调用**。Swift 会把"读"当"写"广播变更 → 视图自激死循环（2026-07-21 三轮卡死的实锤根因，`SpeakerMapper.resolve`）。读路径必须是纯函数；测试已用 `let` 绑定调用做编译级锁死。
2. **先仪表化再猜因**。`PerfCounters` + `sample <pid>` 是排查 SwiftUI 卡死的两件套；界面卡死但计数不动 = 视图自激；计数狂涨 = 发布风暴，两者修法完全不同。
3. **Anthropic messages 的 max_tokens 包含 thinking**。预算不足时 text 会被截断成非法 JSON。旧 K2 网关曾靠关闭 thinking 缓解；K3/K2.7 一旦禁用 thinking 会路由到 K2.6，因此当前 K3 请求必须保持 thinking，并把预算提高到 32768。
4. **os_log 默认全 `<private>`**。脱敏后的安全字段（错误类别、HTTP 状态码、耗时）必须用 `AppLog.logError/logWarning`（privacy public）记录，否则实机无法诊断；但原文、姓名、Key、音频路径**永远**不进日志。
5. **AVAudioFile.read 会短读**（如 536/676 帧），读取必须循环到满；`URLSession` 会把 `httpBody` 转 `httpBodyStream`，测试两种形态兼容。
6. **URLProtocol Mock 与 swift-testing 并行冲突**：用套件内 `.serialized` + 套件专属存储。
7. **deinit 里别释放捕获 self 的 handler 闭包**（释放环）；handler 一律静态化。
8. **异步流消费的测试禁止固定睡眠**，一律条件轮询（5–10s 上限，原断言判定）。高负载下固定睡眠窗口必抖（2026-07-22/23 两轮加固实录）。
9. **测试必须用独立 Keychain service + 每用例独立临时目录**。自动 Keychain 读取必须禁止鉴权 UI；锁定、ACL 不匹配或测试误碰生产条目时应立即失败，不能靠“先解锁钥匙串”掩盖问题。ad-hoc 重签名会改变 App 的 designated requirement，旧凭证可能不再信任新包；稳定跨版本访问必须使用稳定签名身份。
10. **`guard let x` 解包后别再 `if let x`**（阶段 D 掉线遗留的编译错误）；给打开中的工作台刷新存储副本时，**新增 Project 字段记得同步补进 `reloadImportedProjectFromStore` 的字段级刷新清单**（漏了 analysisSnapshots 一次）。
11. **OAuth refresh_token 轮换语义**：Kimi 每次刷新都发新 refresh_token 并作废旧的——刷新成功必须先持久化再返回；多方（App/CLI/测试）共用一个 token 家族会互相刷失效。真实探针消费 CLI 凭证后必须把轮换值写回 CLI 文件。另：`Date` 经 JSON 秒数往返有浮点误差，凭证过期时刻要归一化整秒才能做整组相等断言。
12. **actor 串行不等于异步操作单飞**：actor 方法在 `await` 时允许重入；多个临期请求仍可能同时拿同一个轮换型 refresh_token 发刷新。必须在 actor 内缓存并共享同一个 in-flight `Task`，并让 V1/V2 服务复用同一凭证提供者实例。
13. **AsyncStream 不 finish 就是悬挂**：服务把结果流做成 init 时创建的单一 AsyncStream、会话结束不 finish，靠「流自然结束」收尾的消费方（导入整篇转写）会在 await 处永久悬挂——任务卡 running、0% CPU、无错误无日志。结果流必须每会话新建、cleanup 显式 finish；「等流结束」的一方永远要问一句：谁负责终结这个流？
14. **完整总结与实时分析必须分开持久化**：`finalReportSnapshots` 最多三版，输入指纹覆盖场景、说话人、最终/人工修订片段、项目对话及获授权的旧笔记；新增 Project 字段同步登记字段所有权和工作台刷新清单，不升级 schemaVersion。
15. **通知不能复用旧成功状态**：后台新任务开始时先清空上一条 completion；失败只更新失败状态，不能再次弹出旧报告的“已生成”提示。

## 6. 产品红线（来自计划书，违者返工）

- 不把"AI 推测"写成"事实"；任何分析项必须带真实存在的证据片段 ID，否则不进 UI。
- API Key 只进 Keychain；真实谈判录音、声纹样本、客户资料不进仓库、不进测试夹具、不进日志。
- 云端模型/语言资源不可用时，停止对应模块并显示真实错误，**不静默切换假实现**。
- 外部逐字稿、网页、Markdown 和 MCP 返回内容一律是不可信数据，不能改变系统规则或触发任意工具。
- MCP 只允许搜索/读取；不得开放写入、删除、发消息、上传或执行动作。
- 不做：翻译、回应建议/话术、测谎、情绪/人格判断、账号体系、移动端/Windows、App Store 外发。
- 内部原型口径：不签名公证、不外发；汇报分清"本地已做/本地已验证/远端已生效/客户可交付/真实使用已验证"。

## 7. 当前未决事项（接手先看）

1. 项目对话、笔记按项目授权上传、Kimi K3 优先选择与稳定凭证修复已纳入当前分支本地存档，**尚未 push**。本轮 482 例/69 套件全绿，调试 App 已用稳定本机身份打包、通过签名校验并覆盖安装；原生界面已验证 1254×754 宽屏、961×673 窗口（约 960×640 内容最小尺寸），以及稳定签名版本启动、进入旧项目和打开 AI 设置均不再出现 SecurityAgent 密码框。项目对话、笔记 Inspector 与 K3 设置均可达。
2. 用户 7/21 存的旧静态分析 Key 属 agent-gw 遗留通道，在新网关大概率 401——登录账号后它只是无害的后备条目，可在设置页删除。
3. 说话人识别 provider 决策：OpenAI Key / 讯飞 / 火山 / 维持手动标注（Kimi 无音频接口）。
4. 真实得到大脑/其他 MCP 端点与凭证尚未现场验证；Mock 握手通过不能写成“得到大脑已接通”。
5. K3/K3-256K 真实请求、项目对话、授权笔记开花、完整总结、真实短录音/导入、重开与证据跳转仍需本机现场验收；不得使用真实客户录音或笔记做探针。
6. 装 Xcode 后的回迁项：SwiftData 宏、`swift test`。
7. 分析延迟 1–2 分钟/版 vs 计划 60 秒目标的偏差，需记入交付说明.md「未达指标」。
