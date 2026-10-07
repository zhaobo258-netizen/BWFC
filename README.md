# 帮我分析

Mac 原生录音知识工作台：录音与音视频导入、Apple Speech 转写、说话人整理、有证据的分析与完整总结、项目问答、知识开花、笔记、人物库和轻 CRM。

产品定义从 [PRODUCT.md](PRODUCT.md) 开始。当前主流程是录音项目首页与 A 版双区工作台；早期谈判 Meeting 页面作为兼容路径保留。当前没有跨语言翻译能力。

## 项目文档

| 需要了解 | 入口 |
|---|---|
| 产品定位与范围 | [产品说明](PRODUCT.md) |
| 页面和操作流程 | [功能与交互](docs/product/功能与交互.md) |
| 人物、证据、笔记授权和 AI 输入 | [数据与 AI 规则](docs/product/数据与AI规则.md) |
| 代码对应关系、差异与验收 | [现状差异与验收](docs/product/现状差异与验收.md) |
| 协作及工程约束 | [AGENTS.md](AGENTS.md)、[Agent.md](Agent.md) |
| 源码、包和验证状态 | [交付说明](交付说明.md) |
| 历史改动 | [开发日志](开发日志.md) |

## 构建与验证

主程序是 Swift Package executable，最低 macOS 26，使用 Swift 6 严格并发。现有构建路径面向 Apple Silicon 与 Command Line Tools，不需要生成 Xcode 工程。业务数据采用纯 Swift 模型与 JSON 原子写入，尚未使用 SwiftData。

在本目录执行：

```bash
swift build
Scripts/run_tests.sh
Scripts/make_app.sh release
```

- `Scripts/run_tests.sh` 是项目规定的测试入口；必须核对确实执行了用例。不能把当前 CLT 环境下 `swift test` 的构建完成当作测试通过。
- `Scripts/make_app.sh` 读取 [Info.plist](Resources/Info.plist)，生成 `build/帮我分析-v<版本>.app` 及对应构建清单。无参数默认 Debug；脚本不负责正式安装。
- [备用原生构建脚本](Scripts/make_verified_release.sh) 用于 SwiftPM 构建路径异常时的发布准备，同样需要稳定签名、本地引擎和产物检查。
- 本地分人采用独立 sherpa-onnx 引擎和模型。主 Swift target 未引入第三方 Package，不代表整个产品没有第三方运行依赖，见[引擎说明](Helpers/LocalDiarization/README.md)。
- 各次验证的源码范围与结果见交付说明；文档修改不自动要求重新构建、功能测试或安装。

## 代码地图

| 路径 | 责任 |
|---|---|
| `App/` | 应用生命周期、顶层路由、服务注入、存储和人物协调 |
| `Models/` | 录音项目、人物、业务项目、原话、报告、问答与任务状态 |
| `Features/ProjectHome`、`Features/ProjectWorkspace` | 首页及当前双区工作台 |
| `Features/People`、`Features/BusinessProjects`、`Features/Settings` | 人物库、业务项目和设置 |
| `Core/Audio`、`Core/Transcription`、`Core/Import`、`Core/Diarization` | 录音、转写、导入、分片和整场分人 |
| `Core/Analysis`、`Core/Knowledge` | 文字 AI、上下文、证据校验和知识检索 |
| `Core/Persistence`、`Core/Person` | 字段级保存、迁移、人物与业务真源 |
| `Core/Export`、`Core/Security`、`Core/Logging` | 导出、各 Provider 独立凭证、脱敏日志 |
| `Helpers/LocalDiarization`、`Scripts` | 本地引擎及构建、测试和打包工具 |
| `BangWoFenXiTests` | 合成数据和 Mock 测试；测试存在不代表当前已执行 |

## 数据与安装边界

`Project` 是录音项目真源，`Person` 是跨录音人物真源；异步流水线按字段合并保存。真实录音、声纹、私人文稿、客户资料与凭据不得进入 Git、测试夹具或日志。

API Key 和 OAuth Token 按当前方案保存在本机应用配置，各 Provider 隔离；运行时不访问 macOS Keychain。签名身份使用本机 Keychain，属于不同用途。笔记默认本地，进入 AI 上下文需要项目授权；检索 Obsidian 的开关另行控制。

正式安装目标为 `/Applications/帮我分析.app`。更新必须有当次授权，并执行停点确认、原包与数据备份、稳定签名检查、同卷原子替换及现场核验，详见 [Agent.md](Agent.md)。版本号相同不能证明安装包含当前源码修复。
