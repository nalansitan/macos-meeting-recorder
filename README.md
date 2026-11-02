# macOS Meeting Recorder

本地离线、端侧处理的 macOS 会议录音、实时字幕和说话人识别工具。

使用 Swift / SwiftUI 构建，原生采集麦克风和系统播放声音；音频、字幕、说话人分析和声纹匹配均在本机处理，不上传会议内容，不需要云端推理服务或账号。

## 功能

- **会议录音**：ScreenCaptureKit 双路采集，无需虚拟声卡，不保存屏幕图像；支持整体暂停、单路暂停和实验性软件回声消除。
- **离线实时字幕**：macOS 26+ 使用 Apple SpeechAnalyzer / SpeechTranscriber 端侧模型，结束后导出同名 M4A 和 SRT。
- **本地说话人识别**：可选 Core ML 模型区分说话人，支持手动命名和跨会议声纹匹配；不确定时保留编号或待识别状态。
- **回听与管理**：字幕同步回听、跳转、倍速、历史录音、改名，以及已落盘片段的中断恢复。

## 离线能力与联网边界

模型准备完成后，录音、实时转写、说话人识别、回听和导出均可在本地离线运行。录音、字幕、声纹及姓名不会由本应用上传。

首次构建需要联网获取代码依赖。字幕语言模型需要用户主动通过 Apple 系统服务下载，之后由 macOS 管理；说话人模型需要用户主动从 Hugging Face 下载，也可以导入本地模型。开始录音不会触发模型下载，字幕模型缺失时不会回退到云端识别。

本应用不依赖字幕服务、Docker、网关或本地 HTTP 服务。导出的 M4A / SRT 可自行交给其他工具处理。

## 系统要求

| 能力 | 要求 |
| --- | --- |
| 录音与导出 | Apple Silicon Mac，macOS 15+；本机 Python 3、FFmpeg |
| 离线实时字幕 | macOS 26+，已安装对应语言模型 |
| 本地说话人识别 | 已下载或导入对应 Core ML 模型 |
| 从源码构建 | Swift 6.2+、Xcode Command Line Tools、uv、FFmpeg，首次构建需联网 |

macOS 15 可关闭字幕后使用录音功能。当前仅面向 Apple Silicon，尚未验证 Intel Mac。

## 下载安装包

从 [GitHub Releases](https://github.com/nalansitan/macos-meeting-recorder/releases) 下载 Apple Silicon DMG。当前版本使用临时签名，未经 Apple 公证；导出仍需本机安装 Python 3 和 FFmpeg。请先阅读 [安装、授权与首次使用](docs/install.md)，DMG 内也附有离线说明。

## 构建与启动

在本仓库根目录执行：

```sh
bash scripts/build.sh
open build/会议录音.app
```

构建脚本通过 uv 准备 Python 3.12 构建工具环境（不替换系统 Python），并获取固定版本的 FluidAudio 和 WebRTC AEC 依赖，并进行本地临时签名。安装到应用程序目录：

```sh
ditto "build/会议录音.app" "/Applications/会议录音.app"
open -a "会议录音"
```

导出时会从 PATH 及 Homebrew、MacPorts 等常见安装目录查找 Python 3 和 FFmpeg；二者仍需自行安装。

首次录音需要允许麦克风及屏幕与系统音频录制权限。重新构建后的临时签名可能需要重新授权。

## 使用

1. 在设置中选择麦克风、字幕语言和保存位置，提前准备需要的模型。
2. 如需区分多人，在“说话人识别与姓名”中下载或导入模型并开启识别。
3. 点击“开始录音”；两路音量条用于确认本地发言和电脑声音都有输入。
4. 点击“结束并保存”，等待音频及字幕导出完成；可在应用内回听和查看历史录音。

默认录音保存在 `~/Movies/会议录音/`，模型和人员库保存在 `~/Library/Application Support/MeetingRecorder/Speakers/`。系统音轨会包含其他应用的播放声音，建议佩戴耳机。

完整操作、模型管理、数据格式、恢复边界和验证记录见 [使用与技术说明](docs/usage.md)。其中的命令均在仓库根目录执行。

## 开发与验证

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
bash scripts/test-lifecycle.sh
bash scripts/test-software-aec.sh
bash scripts/test-speakers.sh
bash scripts/test-playback.sh
```

这些测试不采集麦克风；回听测试会播放生成的静音音频。真实设备、长会议、蓝牙切换和多人重叠讲话仍需现场验证。说话人识别为辅助功能，短句、相似声音及重叠语音可能无法可靠区分。当前不提供自动会议摘要或待办提取。

## 打包发布

首次准备：安装并登录 GitHub CLI（`brew install gh`、`gh auth login`），确保具有仓库写权限。

每次发新版，先更新 `Info.plist` 中的版本号和递增构建号，新增对应的 `docs/releases/v<版本>.md` 发布说明，并把代码和说明提交到默认分支。然后一条命令：

```sh
bash scripts/release.sh
```

脚本会依次检查版本、干净工作区、账号权限及标签，运行回归测试，构建 DMG，原子推送默认分支和版本标签，用 `gh` 创建草稿并上传 DMG、SHA256SUMS、安装说明、发布说明和构建信息。所有附件的远端 SHA-256 校验通过后才公开为最新版本。

```sh
bash scripts/release.sh --check       # 仅检查，不构建或推送
bash scripts/release.sh --draft       # 构建上传后停留在草稿
bash scripts/release.sh --prerelease  # 发布为预发布，不设为 Latest
```

失败后可重跑同一命令：同一提交的完整本地包可以复用，草稿中校验一致的附件会跳过。脚本不会覆盖已经公开的版本、移动已有标签或强制推送。若本地包不完整或属于其他提交，请先检查并移走对应 `build/releases/v<版本>/` 目录后重试；若草稿附件内容不一致，请人工核查，脚本不会自动删除远端文件。请勿同时运行多个发布进程。

只生成本地包可运行 `bash scripts/package-dmg.sh`；产物位于 `build/releases/v<版本>/`。DMG 包含 Applications 快捷方式和离线说明，不包含 Python、FFmpeg 或模型。打包仍为临时签名，不会自动完成 Developer ID 签名或 Apple 公证。录音、授权和真实会议效果仍需现场验收。

## 开发协作

项目由 [@nalansitan](https://github.com/nalansitan) 维护，使用 OpenAI Codex 辅助开发、测试和文档整理。此说明用于披露工具参与，不代表 OpenAI 官方维护或背书。

## 许可证

本项目原创代码使用 [Apache License 2.0](LICENSE)。第三方依赖及模型遵循各自的许可，详见 [第三方说明](THIRD_PARTY_NOTICES.md)。模型权重不随源码仓库分发。
