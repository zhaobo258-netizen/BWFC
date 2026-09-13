# LocalDiarization — 本地分人/认人引擎

`bangwo-local-diarization`：独立 CLI 进程，主 App 通过 `Process` 调用（见 `Core/Diarization/LocalSherpaDiarizationService.swift`）。产品与实施合同：仓库父目录 `13_…产品文档_20260913.md`、`14_…技术开发文档_20260913.md`。

## 组成

| 文件 | 说明 | 来源与许可 |
|---|---|---|
| `bangwo-local-diarization.swift` | 引擎主体（selfcheck/diarize/embed 三模式，stdout JSON 合同） | 本项目 |
| `SherpaOnnx-Bridging-Header.h`、`include/sherpa-onnx/c-api/c-api.h` | C API 桥接头与头文件（与库版本严格同 tag） | [sherpa-onnx v1.13.8](https://github.com/k2-fsa/sherpa-onnx)（Apache-2.0） |
| `build.sh` | swiftc 直编；自动解析/下载 pinned 共享库 | 本项目 |

运行依赖（不入 git，构建时自动下载或经 `BWFX_SHERPA_LIB_DIR` 提供）：
`libsherpa-onnx-c-api.dylib`、`libonnxruntime.dylib`（v1.13.8 osx-arm64 shared-no-tts）。

模型（不入 git、不随包分发，用户按设置页指引一次性下载）：
- 分人：`sherpa-onnx-pyannote-segmentation-3-0/model.onnx`（约 6MB）
- 声纹：`campplus-3dspeaker/model.onnx`（CAM++，192 维，约 28MB）
默认模型目录：Application Support/帮我分析/LocalDiarizationModels/。

## 进程合同（v1）

```
bangwo-local-diarization --mode diarize --models <dir> --wav <16k-mono.wav> \
    [--references refs.json] [--threshold 0.5] [--cluster-threshold 0.5] \
    [--num-speakers N] [--max-duration-ms 7200000] [--quiet]
```

- stdout：`{durationMs, segments:[{startMs,endMs,speakerLabel,clusterConfidence,matchAlias?,matchSimilarity?}], engine:{...}}`；匹配到注册声纹的段 `speakerLabel` 为注册别名，否则 `local:N`（全场稳定）。
- stderr：`progress|<0-100>` 与 `error|<code>|<message>`；错误码 `usage/model_missing/model_invalid/audio_unreadable/too_long/internal`，退出码 2/3/4/5/6/1。
- `refs.json`：`[{"alias","wav"}]`，wav 为 16kHz 单声道 16-bit PCM WAV 绝对路径。
- 隐私：仅读取指定 WAV 与模型文件，写出仅限 `--output`/stdout；不联网。

## 边界

- 只支持整场识别；会中 20 秒分片由 App 侧门禁保持"未配置"（`DiarizationController.isProviderConfigured`）。
- 时长上限 2 小时（超限 `too_long`）；长会议分段处理为后续独立工作项。
