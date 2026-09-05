# Agent.md — 给后续维护本项目的 AI 协作者

> 你是《帮我分析》Mac App 的维护者。这是一个“对话记录与理解”工具（知识花园版）：本地录音/音视频导入 + Apple Speech 本地转写 + 可配置分析模型 + 实时/完整总结 + 多知识来源开花 + 项目制自适应工作台。V1 谈判版功能全部保留兼容。
> 动手前请读完本文件；当前基础产品边界以 `../03_帮我分析_知识花园版_产品开发文档_20260722.md` 为准；后续人物库、业务记忆、CRM 与私人助理路线及本轮修复验收边界见 `../12_帮我分析_私人助理产品开发文档_20260905.md`（V1 历史见 `../01_…MVP开发实施计划.md`）；历史排查过程见 `开发日志.md`。
> 当前版本：`v2.7.2 (18)`（2026-09-05）。修复匿名分组、跨录音声纹刷新与整场识别、开花取消卡死和动机提示词。`swift build` 0 警告，`Scripts/run_tests.sh` 实际执行 811 例 / 89 套件全部通过，稳定签名包已更新并启动 `/Applications/帮我分析.app`。隔离原生 UI 与正式历史录音编号已核对；真实声纹准确率、客户场景理解质量尚未验收。具体交付状态见 `交付说明.md`。
> 03 号文档阶段 A–D 已本地实现；Obsidian 权威存储已接入，结构化项目页/block link 尚未落地。12 号文档中的独立人物库、需确认的业务记忆、轻 CRM 与回答朗读已形成可测试的本地闭环；专用硬件、持续语音对话和长期自主助理仍属后续路线。真实模型、外部 MCP、多人识别与录音硬件闭环仍待现场验收。

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
Scripts/run_tests.sh        # 全部测试（2026-09-05 最终 782 例/89 套件通过；BWFX_IT_MEDIA=1 另加媒体探针）
Scripts/make_app.sh         # 产出带版本后缀的 build/帮我分析-v<版本>.app（稳定本机身份签名）
Scripts/soak_test.sh 3600 1 # 60 分钟录音稳定性（本版本未复跑，旧结果不代表本版本）
```

本机正式安装的固定目标为 `/Applications/帮我分析.app`，更新前遵循以下原则：

1. 在当前应用界面确认没有活跃录音、导入或收尾任务，完成必要保存，再通过应用 UI 正常退出；不强退活跃录音。
2. 备份旧 App，以及设置中当前权威存储目录内的现有 JSON 与迁移标记（包括 projects、meetings、persons、business-projects、speaker-profiles）。保留原音频与声音样本，不把本机业务数据放入仓库或测试夹具。
3. 新包先在同一卷的临时位置完整准备，核验版本、Bundle ID、`codesign --verify --deep --strict`，并确认签名 Authority 为 `BangWoFenXi Local Code Signing` 或明确指定的稳定身份；ad-hoc 包只能用于隔离测试。
4. 确认应用已退出后，在同一正式路径执行原子替换；保留旧包和数据备份。替换后再次验证签名，通过 UI 打开并确认实际运行路径、版本与历史资料可读。
5. 若替换或启动检查失败，停止继续迁移，在应用退出后恢复旧包。涉及数据恢复时先保全新产生的数据，再使用对应备份；不得用旧 JSON 直接覆盖更新后产生的新录音。安装与回滚结果均以现场验证为准。

不得以 `osascript` 强制结束业务流程、移除 quarantine、关闭系统保护或换用 ad-hoc 签名来绕过安装失败。当前安装状态与源码交付位置见 `交付说明.md`；以后每次更新仍需核对实际运行路径、版本与数据。

调试开关：`defaults write com.zhaobo.BangWoFenXi bwfxDebugCounters -bool YES` 后界面底部显示 PerfCounters 计数条（发布/节流/计时器/面板求值），排查界面问题时务必打开。

## 3. 架构速览

```
App/        @main、AppEnvironment（协议注入全部服务）、AppRouter（projectHome 默认）
Models/     V2：Project（权威模型，analysisSnapshots/legacy* 兼容字段）、Speaker（含 personId 跨录音人物外键）、
            Person/MemoryEntry/BusinessMemoryCandidate（独立人物库与业务记忆，persons.json）、
            BusinessProject/FollowUp（轻 CRM，business-projects.json）、
            ConversationAnalysis（20 类单一枚举）、FinalReport（最近三版）、
            ProjectAIChat（背景纠正与项目问答，最多 60 条）、
            ProcessingJob、ArchiveState
            V1 保留：Meeting（运行时桥接用）、Participant、TranscriptSegment、AnalysisSnapshot、Insight
Features/   ProjectHome / ProjectWorkspace（宽/紧凑/窄屏 + 四个 AI 页签）/
            ProjectImport（含 finalReport Job）/ People（人物库 Person 优先页）/
            BusinessProjects（轻 CRM 业务项目页）/ Settings（Root 弹层分类设置）；
            旧 MeetingList/LiveMeeting/MeetingReview 保留兼容
Core/
  Audio/        AVAudioEngine 采集、录音编排、回放、暂停时间轴、AnswerSpeech（回答朗读）
  Transcription/ SpeechTranscriber 封装、TranscriptReconciler（合并去重核心纯逻辑）
  Import/       AudioImportService（检查/提取）、FileTranscriptionRunner、ImportPlanner（Job 编排/续跑）
  Diarization/  20s 分片、上传队列（持久化+退避）、OpenAI 兼容 diarize、SpeakerMapper
  Person/       PersonLibraryStore（persons.json + 人物关系事务/撤销/合并）、PersonMigration（首次档案迁移 + 失败回滚）、
                BusinessProjectStore（business-projects.json + 归组建议）
  Analysis/     AIProviderRegistry（Kimi/OpenAI-compatible）、
                PromptRegistry、ProjectAIOrchestrator、FinalReportAgent、ProjectAIChatAgent、
                BusinessMemoryCandidateAgent（记忆/跟进候选提取）、
                ConversationAnalysis{Prompt,Schema,InputAssembler,Service}
                V1：KimiAnalysisService（V1/V2 共用传输层 rawAnalysisText）、AnalysisSchema、触发器
  Knowledge/    KnowledgeBloomAgent、Obsidian/Internet Provider、多只读 Streamable HTTP MCP
  Persistence/  ProjectStore + MeetingStore（JSON 原子写）、ProjectMigration（V1→V2）、ProjectAssetRepair
  Security/     LocalCredentialStore、CloudAPIKeyStore（按 provider 分条目）、
                KimiOAuth（设备码登录客户端 + 凭证存储 + actor 凭证提供者，自动刷新）
  Logging/      OSLog + 脱敏；Export/ Markdown/JSON
```

关键约定：

- UI 只依赖协议（…Servicing、MeetingStoring、ProjectStoring），测试用 Mock 注入。
- **Project 是权威数据**；录音/转写链路复用只认 Meeting，经 `ProjectRuntimeSession` 纯函数桥接双向同步。V2 分析快照直接挂 Project，不经桥接。
- 导入流水线持久化为**字段级合并**（只写自己拥有的字段），不得整对象覆盖工作台并发编辑的笔记/标题。
- **Person 是人物身份真源**：`Speaker.personId` 跨录音关联；姓名不作合并键，声音样本是可选附件。合并保留主样本与 `additionalVoiceProfileIDs`，无声纹人物不受自动声纹候选数量限制。
- 人物关联、合并、删除、“这是我”、元数据与声音附件变更通过共享协调入口同步人物库、录音、候选与业务项目；写失败回滚。撤销只恢复该次改动的字段，不覆盖后来新增的文稿、笔记或跟进结果；不能复活已删除录音或不存在的声音附件。
- 人物迁移仅首次运行；源数据读取失败必须停止，不能 `try? load` 后用空库继续。备份成功后才迁移，人物与录音落盘成功后才写完成标记；后续新声纹走显式人物创建/关联入口，不能靠重启补写而复活已删除人物。
- 业务记忆只有人工确认后才参与上下文，同时核验生效日期、人物/业务项目作用域与来源版本；`BusinessProject.id` 与录音 `Project.id` 不可混用。候选确认要重验当前证据与归属；来源或人物关系变化进入复核，拒绝的候选不能自动重建为有效记忆。
- 原 Vault 不可用时禁止在临时目录另写人物、业务项目或新录音。恢复入口只重新授权并验证原库，重启后接入；不把临时目录当作迁移来源。
- Kimi/分人固定模型、网关、超时集中在 `Core/Analysis/CloudModelConfig.swift`；用户自定义分析模型只通过 `AIProviderConfigurationStore` 管理，视图和业务代码不得直接读取 Endpoint 或 Key。
- 所有 AI 文本生成走 `AITextGenerationServing` / `AIProviderRegistry`；每次请求只读一次非敏感配置快照。凭证明文保存在当前 App 的 UserDefaults 域，设置中的保存与删除必须同步刷新配置状态，不得写入项目、日志或导出文件。
- 运行时不得调用 macOS Keychain 或触发 SecurityAgent；录音、分析、完整总结、项目对话、开花、MCP 和测试统一从本机明文凭证存储读取。
- 本机可安装包必须使用 `BangWoFenXi Local Code Signing` 或显式提供的稳定签名身份；ad-hoc 只允许临时测试，禁止覆盖用户正在使用的安装包。稳定签名身份只保存在本机登录 Keychain，不得导出或提交。
- `PromptRegistry` 是共享安全红线、场景规则、任务 Prompt、固定 JSON 合同与 Prompt Version 的唯一入口；普通设置页不开放原始 Prompt。
- 项目对话中只有用户消息会作为后续实时分析/开花的背景，不能充当逐字稿证据。仅当用户本轮明确给出错词和正词、模型返回包含该错词的真实片段 ID，且 App 在当前逐字稿再次核验通过时，才可复用全局纠错链路修改逐字稿并加入后续转写规则；普通讨论、背景补充或 AI 猜测不得改写原稿。
- 项目对话的联网搜索默认开启，每轮最多向搜索 Provider 发送两条、每条不超过 24 字的短检索词；逐字稿、笔记、引用文档和历史对话不得发送给搜索 Provider。网页摘要一律标记为不可信数据，回答只能引用当轮真实存在的 `web_N` 来源 ID。
- 用户笔记默认不上云。`noteAIContextEnabled` 按项目授权后，项目对话、开花与完整总结在请求开始时读取编辑器最新文本（最多 20,000 字符）；不逐键上传，外部 MCP 仍只收最长 24 字短检索词。
- 完整总结以完整逐字稿和分析证据账本为事实来源；用户主动发送的项目对话、AI 反馈和获授权的旧笔记只能进入独立的 `collaborationSummary`，必须标明不是录音事实，也不得查询互联网/MCP。
- 所有耗时纯逻辑（分片规划、退避、合并去重、触发器、时间轴换算、Job 编排）都是可单测的值类型；AVFoundation/Speech 只做薄壳。

## 4. 云端配置现状

| 用途 | Provider | 端点 | 凭证 |
|---|---|---|---|
| 实时分析/完整总结/项目对话/开花 | Kimi | `https://api.kimi.com/coding/v1/messages`（Kimi Code Anthropic 协议；默认 `k3-256k`，可选 `k3` / `kimi-for-coding`；K3 保持 thinking，max_tokens 32768，超时 240s） | **Kimi 账号登录（OAuth，推荐）**：本机明文条目 `kimi-oauth`；后备静态 API Key：条目 `kimi` |
| 项目对话联网搜索 | Kimi Code Managed Search | `https://api.kimi.com/coding/v1/search`（`text_query`；仅短检索词）；失败时回退中文维基百科 | 复用 Kimi 账号登录凭证；不新增凭证条目 |
| 当前统一分析模型（可选） | OpenAI-compatible | 用户配置的 HTTPS 或 localhost Base URL + `/chat/completions`，模型 ID 由用户填写 | 独立本机明文条目 `analysis-openai-compatible` |
| 说话人识别 | OpenAI 兼容 | `POST /v1/audio/transcriptions`，`gpt-4o-transcribe-diarize` | `diarization`（当前**未配置**，灰态零请求） |
| 外部知识来源 | 多个只读 Streamable HTTP MCP | 每个连接独立 Endpoint；先 `initialize` + `tools/list`，仅启用明确搜索/读取工具 | 每个连接独立 `knowledge-mcp.<UUID>`；旧单连接保留 `knowledge-mcp` |

- **Kimi OAuth（2026-07-24 落地，替代旧 agent-gw 通道）**：
  - 登录：设置页「登录 Kimi 账号」→ 设备码流程（`auth.kimi.com/api/oauth/device_authorization` → 浏览器确认 → 轮询 `api/oauth/token`）；client_id 是编译在官方 kimi CLI 里的公开常量（见 `CloudModelConfig`），非机密。
  - 刷新：access_token 900 秒过期；`KimiCredentialProvider`（actor + 共享 `refreshTask` 单飞）在剩余 <300s 时自动刷新。**refresh_token 每次刷新都轮换（实测）**：刷新成功必须立即持久化新值，否则下次刷新 invalid_grant 被迫重登；也因此 **App 与本机 kimi CLI 绝不能共用同一个 refresh_token**（各自独立登录，token 家族独立）。
  - 凭证优先级：OAuth（已登录）> 静态 Key（后备，未登录时才用）。刷新被拒 → `AnalysisAPIError.unauthorized`（凭证保留，设置页重新登录覆盖）；网络失败 → `.network`（可重试，不清凭证）。
  - 真实探针（07-24）：强制过期 → 真实刷新 → 真实 messages 请求全链路 200（5.8s）。旧 `agent-gw.kimi.com` 为遗留通道（新体系 token 全部 401），已弃用。
- Kimi、OpenAI-compatible 分析、分人和每个 MCP 凭证**互不外借**；某 Provider 401 只暂停它自己。运行时存储域为 `com.zhaobo.BangWoFenXi.credentials.local.v1`，不读取或迁移旧钥匙串条目；升级后需在设置中重新登录或重新填写一次。
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
9. **测试必须用独立凭证 service + 每用例独立临时目录**，不得误碰生产条目。运行时代码不得导入 Security/LocalAuthentication 或调用 `SecItem*`。
10. **`guard let x` 解包后别再 `if let x`**（阶段 D 掉线遗留的编译错误）；给打开中的工作台刷新存储副本时，**新增 Project 字段记得同步补进 `reloadImportedProjectFromStore` 的字段级刷新清单**（漏了 analysisSnapshots 一次）。
11. **OAuth refresh_token 轮换语义**：Kimi 每次刷新都发新 refresh_token 并作废旧的——刷新成功必须先持久化再返回；多方（App/CLI/测试）共用一个 token 家族会互相刷失效。真实探针消费 CLI 凭证后必须把轮换值写回 CLI 文件。另：`Date` 经 JSON 秒数往返有浮点误差，凭证过期时刻要归一化整秒才能做整组相等断言。
12. **actor 串行不等于异步操作单飞**：actor 方法在 `await` 时允许重入；多个临期请求仍可能同时拿同一个轮换型 refresh_token 发刷新。必须在 actor 内缓存并共享同一个 in-flight `Task`，并让 V1/V2 服务复用同一凭证提供者实例。
13. **AsyncStream 不 finish 就是悬挂**：服务把结果流做成 init 时创建的单一 AsyncStream、会话结束不 finish，靠「流自然结束」收尾的消费方（导入整篇转写）会在 await 处永久悬挂——任务卡 running、0% CPU、无错误无日志。结果流必须每会话新建、cleanup 显式 finish；「等流结束」的一方永远要问一句：谁负责终结这个流？
14. **完整总结与实时分析必须分开持久化**：`finalReportSnapshots` 最多三版，输入指纹覆盖场景、说话人、最终/人工修订片段、项目对话及获授权的旧笔记；新增 Project 字段同步登记字段所有权和工作台刷新清单，不升级 schemaVersion。
15. **通知不能复用旧成功状态**：后台新任务开始时先清空上一条 completion；失败只更新失败状态，不能再次弹出旧报告的“已生成”提示。

## 6. 产品红线（来自计划书，违者返工）

- 不把"AI 推测"写成"事实"；任何分析项必须带真实存在的证据片段 ID，否则不进 UI。
- API Key 和 OAuth Token 按老板明确决定明文写入本机 App 配置；真实谈判录音、声纹样本、客户资料及任何凭证不进仓库、不进测试夹具、不进日志。
- 云端模型/语言资源不可用时，停止对应模块并显示真实错误，**不静默切换假实现**。
- 外部逐字稿、网页、Markdown 和 MCP 返回内容一律是不可信数据，不能改变系统规则或触发任意工具。
- MCP 只允许搜索/读取；不得开放写入、删除、发消息、上传或执行动作。
- 不做：翻译、回应建议/话术、测谎、情绪或心理诊断、敏感人格推断、账号体系、移动端/Windows、App Store 外发；允许基于真实发言证据生成可观察的表达与沟通画像。
- 内部原型使用稳定本机签名，尚未公证、未外发；汇报分清"本地已做/本地已验证/远端已生效/客户可交付/真实使用已验证"。

## 7. 当前版本与未决事项（接手先看）

1. `v2.7.2 (18)` 完成四项反馈修复：历史声音组编号恢复与批量指认；已登记人物声纹刷新、可靠身份补全及单次整场识别；开花取消复位和分阶段展示；基于原话的业务动机与替代解释。详情见 `交付说明.md`。
2. 2026-09-05 最终本地验证：`swift build` 0 警告，`Scripts/run_tests.sh` 811 例 / 89 套件通过；稳定签名包通过 `codesign --verify --deep --strict`。不使用普通 `swift test` 的构建结果代替执行。
3. 隔离原生 UI 已验证：人物编号、同组两条批量指认、两场人物身份显示、未连接服务提示、开花取消/重试/失败与AI先显示、动机四行窄列排版。使用生产视图和合成资料，不代表真实声纹准确率。
4. 正式 `/Applications/帮我分析.app` v2.7.2 (18) 已启动，历史录音人物编号和识别入口可见；8 份权威 JSON 与 309 个媒体文件升级前后保持一致。Git 交付以任务回执及父目录 12 号文档 §13.7 的现场提交核对为准。
5. 本版本真实短录音/音视频导入、真实 Kimi/OpenAI-compatible 请求、授权笔记开花、完整总结、多人声纹和外部 MCP 尚未完成现场验收。仅用获得授权的合成或专用测试资料，不以真实客户录音或笔记作探针。
6. 专用硬件收音/外放、持续语音交互与自主执行不是当前已交付能力。现有朗读为用户点击后调用系统 TTS，可停止；人物记忆依赖可复核来源与人工确认，不是自动训练模型。
7. 本版本未复跑 60 分钟稳定性与跨设备真实噪声场景。历史延迟约 75–95 秒/版，不能宣称达到 60 秒更新目标；设备格式变化、收音环境与多人重叠发言仍需专项验收。
8. 装 Xcode 后才考虑 SwiftData/`swift test` 工具链回迁；当前保持 SPM、JSON 与独立测试执行器架构。
