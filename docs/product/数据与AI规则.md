# 数据与 AI 规则

> 核对日期：2026-10-07（CST）｜源码基线：`a91039a`。本文说明该基线已经实现的数据与 AI 行为；源码和测试阅读不代表真实模型、真实知识库或正式安装版已经验收。产品入口见 [PRODUCT.md](../../PRODUCT.md)。

## 1. 数据对象与真源

| 对象 | 当前含义与权威位置 | 不能混同的对象 |
|---|---|---|
| `Project` | 一份录音、导入资料或组合录音工作区；承载文稿、说话人、分析、报告、对话、笔记、任务，保存在 `projects.json`，当前 `schemaVersion = 2` | 不是 CRM 业务项目 |
| `Meeting` | 旧版兼容模型，也是录音、转写链路的运行时桥接对象；通过 `ProjectRuntimeSession` 与 Project 同步 | 不得以旧 Meeting 覆盖 Project 全对象 |
| `TranscriptSegment` | 稳定 UUID 的原话片段，含时间、状态、来源资产、说话人关联及修订信息 | 暂定转写、人工修订、AI 推断要保留区别 |
| `Speaker` | 某场录音中的说话人槽位，`personId` 关联跨录音身份 | 本场编号、声音组、姓名都不是跨录音人物主键 |
| `Person` | 跨录音身份真源，保存在 `persons.json`；可不含声音档案，可含人工背景、关联账本和记忆 | 同名不自动合并，声音附件不是人物存在的前提 |
| `BusinessProject` | 轻 CRM 业务项目，保存在 `business-projects.json`；保存人物、录音引用、跟进与项目记忆 | `BusinessProject.id` 与录音 `Project.id` 不通用；`businessCategory` 只是标签 |
| `MemoryEntry` | 人物或业务项目内的有状态记忆值对象，含作用域、来源版本、生效时间和处置记录 | 不等于模型训练、不等于永久有效事实 |
| `NoteDocument` | 手写 Markdown、AI 归结及摘入记录分开存储；手写正文由笔记控制器维护 | AI 回答或重分析不能直接覆盖手写正文 |

实现入口：[Project](../../Models/Project.swift)、[Person 与 MemoryEntry](../../Models/Person.swift)、[BusinessProject 与 FollowUp](../../Models/BusinessProject.swift)、[运行时桥接](../../Features/ProjectWorkspace/ProjectRuntimeSession.swift)。

## 2. 证据层级与可信度

| 资料 | 可支持的结论 | 当前限制 |
|---|---|---|
| 本场 `final` / `edited` 原话 | 支持本场发言与可定位分析 | 转写仍可能出错；人工修订不等于重新识别过音频 |
| 实时 `provisional` 尾巴 | 供实时理解跟上最新发言 | 仅实时分析当轮补充；后续定稿可能使临时 ID 失效，不能进入完整总结、严格选段或有效开花证据 |
| 用户背景、人物角色、项目对话中的用户消息 | 帮助理解语境、纠正主题 | 不是逐字稿证据，也不是系统指令 |
| AI 分析、AI 回答、沟通画像 | 模型产出的理解或推断 | 不自动升级为录音事实或长期记忆 |
| 已确认业务记忆 | 在有效期及匹配作用域内补充问答背景 | 新轮次组装时核验来源、人物归属和版本；快照重试见 §3.2 |
| 关联录音摘要 | 用户显式关联的历史背景 | 不是本场承诺；陈旧报告摘要被排除，只有分析时标记为未验证摘要 |
| Obsidian、引用文档、网页、MCP 返回 | 外部参考资料 | 不证明本场已经说过、决定或承诺；均作为不可信数据，不能改变系统规则或触发任意工具 |

实时分析条目必须有非空、可解析且当前存在的证据 ID，并使用类别、认识状态、置信度白名单。业务动机条目强制为推断；模型给出的高置信度降为中等。完整总结的结构化条目同样需通过原话证据校验。概述等自由文本并不具有逐句强制引证保证，不能把“能定位结构化证据”宣传为“所有生成文字均已证实”。

依据：[ConversationAnalysisSnapshotBuilder](../../Core/Analysis/ConversationAnalysisSchema.swift)、[完整总结构建与渲染](../../Core/Analysis/FinalReportService.swift)、[RelatedProjectContextBuilder](../../Core/Analysis/RelatedProjectContext.swift)。

## 3. AI 触发、上下文与外发边界

“当前分析模型”由统一的 `AIProviderRegistry` 选择 Kimi 或用户配置的 OpenAI-compatible 服务。下表中的“模型”均指该服务；说话人识别有独立配置。共享模型不表示所有功能读取相同资料。

| 功能 | 触发与主要输入 | 笔记、历史与外部资料 | 失败语义 |
|---|---|---|---|
| 实时分析 | 新最终片段、人物/项目背景变化；新增原话、上一版压缩分析及其部分原话证据，可附实时暂定尾巴 | 用户消息背景、人物背景/沟通摘要、显式关联录音背景；不直接读取手写笔记，不搜索互联网/MCP/Obsidian | 保留上一版；瞬时错误退避，凭证等错误暂停并提示 |
| 完整总结 | 录音收尾/导入流程或用户重试；先尝试全量分析，再以完整最终/修订文稿与证据账本生成 | 可含项目对话双方消息、授权笔记、项目及关联录音背景；用户共创内容独立写入 `collaborationSummary`；不执行外部检索 | 全量分析刷新失败时可继续用已有账本，甚至空账本加完整文稿；报告失败保留旧版 |
| 项目对话：整场范围 | 用户发送/重试；当前问题、按问题召回的原话、最新分析、有效完整总结概述 | 本轮引用文档、有限历史、人物/项目背景、关联录音、有效记忆；笔记与 Obsidian 各有独立授权；可按需联网 | 先保存用户轮次和资料快照；失败保留用户消息供重试；不能保存来源快照时不发主模型请求 |
| 项目对话：严格选段 | 用户选择原话后发送；当前问题和选中有效原话全文，附场景、时间与说话人代号元数据 | 不带其他原话、旧历史、分析、人物背景、项目背景、关联录音、记忆、笔记或引用文档；联网和 Obsidian 必须关闭 | 新建请求时任一选段失效、空选段或超预算直接失败，不裁掉所选原文、不回退整场；有快照重试沿用当时原话 |
| 开花 | 用户主动选择种子；种子、有效原话、场景、用户消息背景及授权笔记 | 模型联想与本地 Obsidian 初检并行；再用短关键词搜索 Obsidian、互联网、已启用只读 MCP；实际来源可交模型做知识速览 | 联想、来源、速览分阶段显示；来源失败不抹掉已生成联想，速览失败仍可查看资料 |
| 记忆/跟进候选 | 收尾流程或用户重提；已人工确认人物归属的最终原话、相关有效记忆 | 不是整库学习；无需联网知识检索；结果仍须人工处置 | 来源在请求期间变化则拒绝应用，未确认候选不进入后续问答 |

实现入口：[统一模型配置](../../Core/Analysis/AIProviderConfiguration.swift)、[实时分析控制器](../../Features/ProjectWorkspace/ConversationAnalysisController.swift)、[完整总结协调器](../../Features/ProjectWorkspace/FinalReportCoordinator.swift)、[项目对话服务](../../Core/Analysis/ProjectAIChatService.swift)、[开花 Agent](../../Core/Knowledge/KnowledgeBloomAgent.swift)、[记忆候选服务](../../Core/Analysis/BusinessMemoryCandidateService.swift)。

### 3.1 请求预算与保留上限

| 项目 | 当前代码限制 |
|---|---|
| 实时录音分析调度 | 2 个新最终片段，或最早待分析片段等待 30 秒；通常防抖 5 秒；失败退避 30 秒。默认批处理触发器为 3 段 / 45 秒 / 10 秒防抖 |
| 实时分析上一版原话证据 | 最多 24 段、12,000 字符；本轮新增片段与最终全量分析不受这个旧证据预算限制 |
| 实时分析历史 | 最近 5 版快照 |
| 项目对话问题 | 每条最多 4,000 字符 |
| 整场范围原话 | 总计最多 30,000 字符、每段最多 1,000 字符；按关键词/人物命中、相邻段和全场时间采样选择，不代表每轮读完整场 |
| 严格选段原话 | 有效选中段全文合计最多 30,000 字符；超限拒绝本轮 |
| 项目对话历史 | 最后 16 条消息，每条最多 2,000 字符；本地消息最多 60 条，按整轮淘汰 |
| 当前引用文档 | PDF、Word、Markdown、文本/RTF；最多 4 份，每份 16,000 字符、合计 48,000 字符；单文件最多 25 MiB，需能抽取文字 |
| 历史引用文档 | 来自保留的对话历史，单份最多 8,000 字符，合计 20,000 字符 |
| 授权笔记 | 项目对话、开花、完整总结各自最多 20,000 字符 |
| 完整总结共创上下文 | 最近 30 条消息，每条最多 3,000 字符，总计最多 40,000 字符；附件在此只保留文件名，不重新附其全文 |
| 完整总结版本 | 最近 3 版；最新 Markdown 独立保存 |
| 关联录音 | 最多 8 个；单个背景最多 4,000 字符、摘要最多 6,000 字符；标题/标签另有限制 |
| 项目对话有效记忆 | 最多 12 条、内容合计 4,000 字符，按更新时间倒序 |
| 记忆候选输入 | 至少 2 段已确认人物归属的有效原话；最近最多 200 段 / 24,000 字符 |
| 开花 | 最多 12 个候选种子；当轮原话证据最多 3 段、每段 1,000 字符；模型分支最多 8 条；实际精炼检索最多 2 个关键词，每 Provider 每词请求最多 4 条结果；来源速览最多 8 条、每条摘录最多 1,200 字符 |

这些是代码预算或调度阈值，不是模型延迟、内容完整性或实时性 SLA。完整总结目前直接组装完整有效文稿；没有“任意长录音都能无损分块总结”的实现保证。

依据：[AnalysisTrigger](../../Core/Analysis/AnalysisTrigger.swift)、[增量输入组装](../../Core/Analysis/ConversationAnalysisInputAssembler.swift)、[项目对话请求构建](../../Core/Analysis/ProjectAIChatService.swift)、[对话保留与附件](../../Models/ProjectAIChat.swift)、[FinalReport](../../Models/FinalReport.swift)、[KnowledgeGardenController](../../Features/ProjectWorkspace/KnowledgeGardenController.swift)。

### 3.2 用户笔记不是自动上传通道

`noteAIContextEnabled` 按项目保存，默认关闭，旧数据缺字段也默认关闭。开启后，项目对话和开花在请求时读取编辑器最新正文；完整总结读取项目中已保存的笔记及归结。不会每次按键发模型请求，也不会因此启用实时分析读取笔记。

笔记控制器默认 800 ms 防抖落盘；离开/收尾等流程会立即保存。保存失败显示错误，内存正文保留，不能报告已保存。AI 归结与手写正文分别保存，只有用户执行“摘入笔记”时追加内容，并按归结 ID 防重复；不会覆盖既有手写内容。

关闭笔记授权影响新请求的资料组装；已经保存的旧轮次及其资料快照不会被自动删除。重试有快照的旧轮次会恢复当时请求内容，可能重新发送当时已授权笔记。旧轮重试也恢复当时原话与业务记忆，即使它们后来发生变更；严格选段快照同样不重新核验当前原话。公开网页搜索则可能重新执行，不属于冻结资料。若要使用当前资料与当前开关，应发送新一轮问题。已主动发送的用户消息也不会因关闭笔记开关而退出对话历史；实时分析和开花可取最近 20 条用户消息、每条最多 2,000 字符作为背景，AI 回答不走这条用户背景入口。

依据：[NoteController](../../Features/ProjectWorkspace/NoteController.swift)、[ProjectAIUserContext](../../Models/ProjectAIChat.swift)、[请求与快照恢复](../../Core/Analysis/ProjectAIChatService.swift)、[工作台授权与上下文供应](../../Features/ProjectWorkspace/ProjectWorkspaceView.swift)。

### 3.3 外发内容不能笼统称为“完全匿名”

结构化说话人身份通常使用本地云端代号，而非直接传显示姓名；但用户问题、原话、笔记、人物背景、记忆作用域说明、关联录音标题、引用文档、来源标题或相对路径仍可能包含姓名及业务信息。不能承诺“任何真实姓名或客户资料永不上传”。应按功能和当轮授权说明实际传给当前模型的资料。

联网搜索与主模型请求是两条边界：搜索规划模型只接收当前一条问题；搜索 Provider 只接收校验后的最多 2 条、每条 2–24 字的短词，不接收逐字稿、笔记、历史对话、引用文档和 Obsidian 摘录。关键词策略会拒绝长句、URL、邮箱、连续长数字和部分与私有原文重合的查询，但不是语义脱敏器，无法保证短查询绝不含私人主题。

项目对话联网默认开启，使用 Kimi Managed Search，失败可回退中文维基百科。若当前问题只询问 Obsidian/知识库/历史资料，且未同时明确提到联网/公开资料，则即使联网开关打开也跳过公开搜索与搜索规划。模型回答的引用 ID 必须能匹配当轮真实 `web_N` 或 `obsidian_N` 来源，伪造 ID 被过滤。若模型未给出任何有效来源 ID，当前实现展示全部当轮真实来源；来源列表不等于回答逐句有引证。

外部 MCP 当前用于开花，必须是已验证的只读 Streamable HTTP 连接；只接受 HTTPS 或 localhost HTTP，禁止重定向。多个合适工具时需要选择，写入、删除、上传、发消息、执行类工具不启用。每个连接独立凭证；删除连接不删除历史检索结果。项目对话当前没有直接查询外部 MCP 的路径。

MCP 工具筛选依据声明的工具名称、描述和输入 Schema，不是对远端实现进行安全审计。当前云端凭据按 Provider/连接分别存放在本机 App 的 UserDefaults 明文条目中，不在运行时访问 macOS Keychain；这是当前已采用的存储方式，不能沿用旧文档中的 Keychain 口径。凭据不写入 Project、导出资料或正文日志。

依据：[项目对话搜索与引用校验](../../Core/Analysis/ProjectAIChatService.swift)、[短词策略](../../Core/Knowledge/KnowledgeProvider.swift)、[InternetKnowledgeProvider](../../Core/Knowledge/InternetKnowledgeProvider.swift)、[ExternalMCPKnowledgeProvider](../../Core/Knowledge/ExternalMCPKnowledgeProvider.swift)、[LocalCredentialStore](../../Core/Security/CredentialStore.swift)。

## 4. Obsidian 的两种职责

### 4.1 权威存储位置

未连接 Vault 时，使用 App 的 Application Support 存储根。连接有效 Vault 后，权威根为所选 Vault 内的 `帮我分析/`，JSON、录音、导入原件和报告在同一根下保存。路径由用户选择及 security-scoped bookmark 解析，不把个人 Vault 路径写死。

这不是把每个 Project 自动渲染成一套 Obsidian 页面。当前主要是权威文件存储，另有 `Meetings/<Project UUID>/完整总结.md`。结构化项目页、独立逐字稿 Markdown 的 block 锚点、全量双向笔记同步仍未形成完整能力。

### 4.2 历史知识检索

开花和项目对话可复用本地 `ObsidianKnowledgeProvider`。该 Provider 只检索可读 Markdown，默认跳过 Vault 根下 `帮我分析/` 自身，避免自引用；隐藏文件、包目录、越出 Vault 的符号链接不进入检索。索引最多 5,000 篇，每文件不超过 2 MB，正文索引最多取前 80,000 字符，全库正文字符预算 12,000,000；超正文预算时仍可能按标题匹配。不会解析 PDF、图片或音视频，也不是向量检索/全库穷尽分析。

每次搜索检查文件新增、修改和删除，未变正文可复用缓存；结果返回前再次实际读取文件。命中范围、截断和不可读文件都会限制结果，未命中不等于资料不存在。

项目对话的 Obsidian 开关与笔记开关相互独立：

1. Vault 已连接只代表本地读取条件，不能自动等同于项目对话的云端授权。
2. “引用 Obsidian”默认关闭；切项目、重开项目、切到严格选段均关闭。
3. 开启后用当前问题在本地检索；指代追问无结果时，可用上一条用户问题补一次本地搜索。
4. 当轮最多取 6 篇、每篇最多 1,800 字符的真实 Markdown 摘录。摘录会进入当前分析模型，因此这不是纯本地回答。
5. 模型只收到标题、摘录、来源 ID 和 Vault 相对路径；本机绝对文件 URL 只用于本地来源跳转。
6. 未连接、未找到、读取失败分别提示；成功也明确只选取部分资料。来源准备后先保存快照，再发送模型。
7. 成功、空结果和失败都按轮次冻结。模型失败后重试不因 Vault 文件变化改换原证据；旧消息缺少授权字段时不自动授权，新轮开关不能借给无快照旧消息。

开花是另一条主动操作路径：点击开花时读取启用 Provider，连接 Vault 时可检索 Obsidian，其来源摘录也可用于云端知识速览；并不依赖项目对话的“引用 Obsidian”开关。

依据：[ObsidianKnowledgeProvider](../../Core/Knowledge/ObsidianKnowledgeProvider.swift)、[项目对话 prepare/reply](../../Core/Analysis/ProjectAIChatService.swift)、[逐轮上下文快照](../../Models/ProjectAIChatScope.swift)、[ProjectAIChatController](../../Features/ProjectWorkspace/ProjectAIChatController.swift)、[KnowledgeBloomAgent](../../Core/Knowledge/KnowledgeBloomAgent.swift)。

## 5. 人物、业务记忆与跟进

人物关联、合并、删除、“这是我”、姓名/背景和声音附件变更通过共享协调入口处理，同步人物、录音关联、候选与业务项目。合并可保留主声音档案和附加档案；整个人物库最多一位“这是我”。撤销只恢复本次修改的字段，不覆盖后来新增的文稿、笔记或跟进结果；冲突时拒绝盲目恢复，不复活已删除录音或已不存在的声音附件。

记忆分为人工背景、口径与术语、已确认约束、持续事项。状态为候选、有效、需复核、已取代、已拒绝。AI 候选保存在来源录音 Project，默认不生效；用户可以改写后确认、仅留本场或拒绝。确认时重新核对当前及已保存原话、来源版本、人物存在与归属，要求业务项目作用域的候选必须选择真实业务项目，不能升级为全局通用记忆。

确认后的记忆写入 Person 或对应业务项目。若人物库已保存成功但来源候选状态未保存成功，界面提示“候选状态待恢复”，后续按同一 ID 对账，不重复创建。被拒绝/仅留本场的候选保留处置记录，不对同一输入自动重新提出；这不等于禁止用户后来主动建立新的人工记忆。

新轮次组装及无快照旧轮的兼容重建通过 `applicableMemories` 检查当前记忆；有快照重试恢复当时的记忆，不走这次筛选。当前筛选条件为：

- 状态有效，生效时间已到且未过期。
- 人物属于本场，限定业务项目处于进行中且关联本场。
- 有录音来源时，录音/片段仍存在，片段为最终或修订稿、人物归属经过人工确认，来源文字、时间、人物及确认状态计算出的版本仍一致。
- 无录音来源时，必须明确标记为人工创建；没有来源的 AI 条目不能冒充人工背景。

原话改动、改人、合并/解除人物关系或删除来源录音，会让相关有效/候选记忆进入复核或在读取时被排除；已拒绝和已取代条目也不参与上下文。冲突提示是启发式辅助，不是自动裁决事实。

跟进候选确认后进入业务项目，处理状态为待跟进、进行中、已完成。没有证据的责任人或期限应留空；完成需要填写实际结果，点击完成不代表客户已经接受。业务项目归档/删除、录音删除与人物删除是不同操作，不应互相推导为级联删除全部原始资料。

依据：[人物事务与字段级撤销](../../Core/Person/PersonLibraryStore.swift)、[记忆候选版本/去重](../../Core/Analysis/BusinessMemoryCandidateService.swift)、[记忆确认与跟进入口](../../Features/ProjectWorkspace/ProjectWorkspaceView.swift)、[适用记忆筛选](../../App/AppEnvironment.swift)、[业务项目存储](../../Core/Person/BusinessProjectStore.swift)。

## 6. 保存、迁移、恢复与删除

### 6.1 字段所有权与原子写入

`ProjectPersistence.upsert` 按调用方拥有的字段合并。笔记只维护手写正文和摘入记录；AI 对话维护消息、草稿、范围、笔记授权和新增归结；运行时维护状态、媒体路径、时间轴和流水线片段；分析、完整总结、开花、候选各有独立字段组。导入流水线不得全对象覆盖最新标题、笔记、人工场景与人物编辑。`all` 是显式全量操作，不能作为普通后台持久化捷径。

JSON 使用原子文件写入；“单文件原子”不等于所有跨文件业务操作都具有数据库事务。Project JSON 解码失败会尝试保全为 `projects.corrupt-*.json` 并报错；保全失败则阻止覆盖写入。这是保全损坏证据，不是自动修复原数据。人物关系协调器另有回滚和字段级撤销机制。

完整总结最新文件写入前核对前版哈希，发现外部修改先保留冲突副本；报告与 JSON 保存失败时尝试恢复旧文件及旧快照。超时、断网、限流、服务错误最多自动重试 2 次，等待 15 秒、30 秒；凭证、截断、格式不合规等不按这条瞬时失败策略重试。

### 6.2 迁移和原 Vault 恢复

V1 → V2 与首次人物迁移有独立完成标记。人物迁移前备份权威文件，读取源失败不能用空库继续；人物与录音落盘完成后才写完成标记。以后新声音档案应显式创建/关联人物，不能依赖重启重跑迁移。

正常切换 Vault 先复制到临时准备目录，核对文件清单并复读权威 JSON，成功后再切换，源目录保留。录音、导入、收尾或完整总结任务活跃时禁用存储切换。目标已有冲突内容时停止，不能静默覆盖。

已使用的原 Vault 无法访问时，不会继续把新录音、人物或业务项目写到另一个永久位置。App 用受限内存状态显示恢复入口，录音/导入及持久写入停用；重新授权必须验证原 `帮我分析` 项目库可读，再重启接入。临时目录不是可交付新库，也不是后续迁移来源。这与“从未连接 Vault 时使用 Application Support”是两种不同状态。

### 6.3 删除边界

删除录音项目先从项目账本摘除，标记其不可再接受后台写入，取消相关总结/导入任务，随后清理人物与业务项目关联、将来源记忆标为需复核，再删除该项目媒体目录。人物身份保留；业务项目里的跟进不自动删除。该流程跨多个文件，若中途失败须如实报告，不能承诺绝对的全有或全无事务。

旧 Meeting 已迁为 V2 Project 时，旧入口不能单独删除媒体而留下权威 Project。删除人物也不等于删除关联录音；它改变身份关系与记忆有效性。持久数据删除仍须用户明确执行，文档维护、版本升级或模型失败不能隐式清库。

依据：[字段合并与删除协调](../../App/AppEnvironment.swift)、[JSONProjectStore](../../Core/Persistence/ProjectStore.swift)、[存储解析/迁移/文件边界](../../Core/Persistence/MeetingFileStore.swift)、[ProjectMigration](../../Core/Persistence/ProjectMigration.swift)、[PersonMigration](../../Core/Person/PersonMigration.swift)、[报告写入与回滚](../../Core/Analysis/FinalReportService.swift)。

## 7. 导出范围

当前项目导出可勾选原始录音、完整转写、实时总结、动机与目的、完整总结、开花与知识延展、AI 共创记录、项目笔记。只导出本项目实际可用的所选内容；在目标目录先准备临时文件夹，再整体移为结果文件夹，遇到同名另建名称。

这是面向阅读和携带的资料导出，不是完整可恢复备份：开花 Markdown 不包含全部 Provider 状态与逐条原始连接账本，AI 共创 Markdown 不包含逐轮结构化请求快照或附件全文，人物库/业务项目/凭据也不是该导出的一部分。旧版 Meeting Markdown/JSON 导出属于兼容能力，不能据此宣称 V2 的全部关系数据已导出。

依据：[ProjectExportService](../../Core/Export/ProjectExportService.swift)、[ProjectExportSheet](../../Features/ProjectWorkspace/ProjectExportSheet.swift)、[旧版导出](../../Core/Export/MeetingExportService.swift)。

## 8. 尚未实现或尚未证实的范围

| 范围 | 应使用的当前口径 |
|---|---|
| Obsidian 结构化项目页、独立逐字稿 block link、手写笔记双向同步 | 仍是后续工作；权威文件存储与现有报告 Markdown 不等于这些能力已完成 |
| 项目对话直接调用任意 MCP、读取整个知识库或 PDF/图片知识库检索 | 未实现；目前是有限 Markdown 本地检索，MCP 接入用于开花 |
| 任意长资料的无损总结、语义级隐私脱敏 | 当前没有这类保证，应显示预算和失败，不以截断后输入冒充全量覆盖 |
| 已确认记忆自动训练模型、持续自主执行、自动对外跟进 | 未实现；当前是本地记录、检索上下文和人工确认 |
| 真实模型回答质量、真实 Vault 召回完整性、真实 MCP 可用性 | 本文未现场验收；不能用静态代码阅读或合成测试代替 |

旧 03 号文档中的“完整总结永不读笔记”“Vault 失权直接回退继续使用 Application Support”“每条 MCP Token 存 Keychain”等表述已过时；当前实现见本文件及对应源码，仍未满足的要求见差异清单。03/12 号历史资料仍保留产品意图和阶段验收历史，不应继续混作当前实现合同。

## 9. 定向验证入口

以下为当前仓库可定位的合成/隔离测试入口。本次文档重构只阅读这些测试与源码；未以本文件宣称执行通过，执行结果由本次交付记录单独说明。需要执行时使用仓库约定的 [Scripts/run_tests.sh](../../Scripts/run_tests.sh)，确认确有用例运行。

| 规则 | 测试入口 |
|---|---|
| 项目对话范围、来源、附件、笔记、逐轮快照 | [ProjectAIChatTests](../../BangWoFenXiTests/ProjectAIChatTests.swift)、[ProjectAIChatSourceTests](../../BangWoFenXiTests/ProjectAIChatSourceTests.swift)、[ProjectWorkspaceM2Tests](../../BangWoFenXiTests/ProjectWorkspaceM2Tests.swift) |
| Obsidian 默认关闭、隔离、来源预算、快照落盘失败、重试冻结、迟到结果 | [ProjectAIChatObsidianTests](../../BangWoFenXiTests/ProjectAIChatObsidianTests.swift)、[ObsidianKnowledgeProviderTests](../../BangWoFenXiTests/ObsidianKnowledgeProviderTests.swift) |
| 分析证据与完整总结 | [ConversationAnalysisInputAssemblerTests](../../BangWoFenXiTests/ConversationAnalysisInputAssemblerTests.swift)、[ConversationAnalysisSchemaTests](../../BangWoFenXiTests/ConversationAnalysisSchemaTests.swift)、[FinalReportTests](../../BangWoFenXiTests/FinalReportTests.swift) |
| 开花证据/失败状态、手写笔记保护 | [KnowledgeGardenTests](../../BangWoFenXiTests/KnowledgeGardenTests.swift)、[NoteControllerTests](../../BangWoFenXiTests/NoteControllerTests.swift) |
| 人物/记忆/业务项目与字段合并 | [PersonLibraryStoreTests](../../BangWoFenXiTests/PersonLibraryStoreTests.swift)、[AppEnvironmentMemoryTests](../../BangWoFenXiTests/AppEnvironmentMemoryTests.swift)、[BusinessMemoryCandidateTests](../../BangWoFenXiTests/BusinessMemoryCandidateTests.swift)、[BusinessProjectStoreTests](../../BangWoFenXiTests/BusinessProjectStoreTests.swift)、[ProjectStoreTests](../../BangWoFenXiTests/ProjectStoreTests.swift) |
| 存储恢复、迁移、删除、导出 | [MeetingFileStoreTests](../../BangWoFenXiTests/MeetingFileStoreTests.swift)、[PersonMigrationTests](../../BangWoFenXiTests/PersonMigrationTests.swift)、[ProjectMigrationTests](../../BangWoFenXiTests/ProjectMigrationTests.swift)、[MeetingDeletionTests](../../BangWoFenXiTests/MeetingDeletionTests.swift)、[ProjectExportTests](../../BangWoFenXiTests/ProjectExportTests.swift) |
