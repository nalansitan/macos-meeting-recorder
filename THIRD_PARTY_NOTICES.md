# 第三方依赖与模型

项目的 MIT 许可证仅适用于本项目原创代码，不替代第三方许可。

- **FluidAudio**：固定提交见 `Package.swift` / `Package.resolved`；SDK 使用 Apache-2.0。构建时将上游许可证复制到应用资源中的 `FluidAudio-LICENSE.txt`。
- **说话人模型**：Pyannote segmentation 与 WeSpeaker embeddings 的 Core ML 转换模型通过用户操作从 Hugging Face 下载或本地导入。模型权重不在源码仓库中分发；模型作者和使用条款以对应模型卡及上游许可为准。详见 [模型说明](Resources/Speaker-Models-NOTICE.txt)。
- **WebRTC Audio Processing / Abseil**：由 `scripts/build-aec.sh` 获取固定版本及校验的源码。构建脚本将相关许可打包到应用的 `Contents/Resources/AEC-Licenses/`。
- **FFmpeg**：当前导出调用用户本机安装的可执行程序，不将其打包分发。
- **Apple 系统框架与语言模型**：由 macOS 提供或管理，不作为本项目源码或模型资产分发。

发布预编译应用时，需要保留所含依赖的许可文件；如改变依赖或开始随包分发模型、FFmpeg，应重新检查相应分发条款。
