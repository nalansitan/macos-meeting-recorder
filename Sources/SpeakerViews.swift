import SwiftUI

struct SpeakerSettingsView: View {
    @ObservedObject var controller: SpeakerController
    let locked: Bool
    let download: () -> Void
    let importModels: () -> Void
    var body: some View {
        GroupBox("说话人识别与姓名") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("实时区分双方的不同说话人", isOn: $controller.enabled).disabled(locked)
                Text(controller.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("模型保存位置").font(.caption).foregroundStyle(.secondary)
                Text(SpeakerController.models.path).font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("打开模型目录") { controller.showModelDirectory() }.disabled(locked)
                    Button("导入本地模型…", action: importModels).disabled(locked)
                }
                Link("手动下载模型（Hugging Face）", destination: URL(string: "https://huggingface.co/FluidInference/speaker-diarization-coreml/tree/main")!)
                    .font(.caption)
                Text("手动下载后先解压，再选择同时包含 pyannote_segmentation.mlmodelc 和 wespeaker_v2.mlmodelc 的文件夹。请下载完整目录，不要只下载单个权重文件。导入会自动复制到上述位置；更换模型版本后需重新登记声纹。")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.importing {
                    HStack { ProgressView().controlSize(.small); Text("正在导入并验证模型……").font(.caption) }
                } else if controller.downloading {
                    ProgressView(value: controller.progress)
                    Text("下载中，请保持应用打开；失败后可重试。").font(.caption)
                } else {
                    HStack {
                        if !controller.ready { Button("从 Hugging Face 下载模型", action: download).disabled(locked) }
                        Button("检查本地模型") { controller.refreshModel() }.disabled(locked)
                    }
                }
                Text("仅下载时联网。每路约 4 秒分析一次，人物标签稍后补充；共用模型、串行分析，繁忙时跳过人物分析，不阻塞录音。新人物需至少 3 个清晰片段、累计 6 秒确认；短句、回声和重叠发言保留待识别。")
                    .font(.caption).foregroundStyle(.secondary)
                if !controller.people.isEmpty {
                    Divider()
                    Text("已记住的人员（仅本机）").font(.headline)
                    ForEach(controller.people) { person in
                        HStack {
                            Text(person.name)
                            Spacer()
                            Button("删除声纹", role: .destructive) { controller.forget(person.id) }.disabled(locked)
                        }
                    }
                }
            }.padding(8)
        }
    }
}

struct SpeakerNamesView: View {
    @ObservedObject var controller: SpeakerController
    @Environment(\.dismiss) private var dismiss
    let locked: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("标注说话人").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("为本场说话人命名，或关联已记住的人员。记住声纹后，新录音会自动匹配；不确定的结果保留编号。已导出的 SRT 请点击“保存录音”更新。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(controller.speakers) { speaker in
                        SpeakerNameRow(controller: controller, speaker: speaker).disabled(locked)
                    }
                    if controller.speakers.isEmpty { Text("尚未识别到说话人。请先下载并开启模型，让每人清晰发言几秒。").padding() }
                }
            }
            Text(controller.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(20).frame(width: 620, height: 480)
    }
}

@MainActor private final class SpeakerNameDraft: ObservableObject {
    @Published var name = ""
    @Published var person = ""
    @Published var remember = true
}

private struct SpeakerNameRow: View {
    @ObservedObject var controller: SpeakerController
    let speaker: MeetingSpeaker
    @StateObject private var draft = SpeakerNameDraft()
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(speaker.label + (speaker.confirmed ? "（已确认）" : speaker.name == nil ? "" : "（自动匹配，可纠正）")).font(.headline)
                Picker("关联人员", selection: $draft.person) {
                    Text("新姓名 / 仅本场标注").tag("")
                    ForEach(controller.people) { Text($0.name).tag($0.id) }
                }
                HStack {
                    TextField("姓名", text: $draft.name).disabled(!draft.person.isEmpty)
                    Button("保存标注") {
                        let selected = controller.people.first { $0.id == draft.person }
                        controller.annotate(id: speaker.id, name: selected?.name ?? draft.name, remember: draft.remember, personID: selected?.id)
                        if let id = controller.speakers.first(where: { $0.id == speaker.id })?.personID,
                           controller.people.contains(where: { $0.id == id }) { draft.person = id }
                    }.disabled(draft.person.isEmpty && draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Toggle("记住此人的声纹，用于其他录音", isOn: $draft.remember)
                Text("仅手动确认后更新声纹；请确认此编号没有混入其他人的声音。").font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }.onAppear {
            draft.name = speaker.name ?? ""
            if let id = speaker.personID, controller.people.contains(where: { $0.id == id }) { draft.person = id }
        }
    }
}

struct SpeakerStatusView: View {
    @ObservedObject var controller: SpeakerController
    var body: some View {
        if controller.enabled {
            Text(controller.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}
