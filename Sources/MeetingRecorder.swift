import AppKit
import AVFoundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var recorder: Recorder?
    private var deciding = false
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder else { return .terminateNow }
        guard !deciding else { return .terminateCancel }
        if recorder.busy {
            recorder.message = "正在处理，请完成后再退出。"
            return .terminateCancel
        }
        deciding = true
        Task { @MainActor in
            let leave = await recorder.prepareToLeave("退出应用")
            deciding = false
            sender.reply(toApplicationShouldTerminate: leave)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RecordingWindowHook: NSViewRepresentable {
    let delegate: AppDelegate
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.delegate = delegate }
    }
}

@MainActor private final class RecorderUIState: ObservableObject {
    @Published var settingsVisible = false
    @Published var settingsSection = "audio"
    @Published var detailsVisible = false
    @Published var playbackVisible = false
    @Published var speakersVisible = false
}

@MainActor private final class CaptionScrollState: ObservableObject {
    @Published var followLatest = true
    @Published var userScrolling = false
    @Published var atBottom = true
}

// Keep meter/timer publications from rebuilding the transcript. Lay out visible rows only.
private struct CaptionTranscriptView: View, Equatable {
    let text: String
    let fontSize: Double
    let folder: URL?
    @StateObject private var scroll = CaptionScrollState()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.fontSize == rhs.fontSize && lhs.folder == rhs.folder
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: fontSize))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("captionEnd")
                }.padding(.vertical, 4)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 32
            } action: { _, bottom in
                scroll.atBottom = bottom
                if scroll.userScrolling { scroll.followLatest = bottom }
            }
            .onScrollPhaseChange { _, phase in
                scroll.userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                if phase == .idle && scroll.atBottom { scroll.followLatest = true }
            }
            .onChange(of: text) {
                if scroll.followLatest && !scroll.userScrolling { proxy.scrollTo("captionEnd", anchor: .bottom) }
            }
            .onChange(of: fontSize) {
                if scroll.followLatest { proxy.scrollTo("captionEnd", anchor: .bottom) }
            }
            .onChange(of: folder) { scroll.followLatest = true; proxy.scrollTo("captionEnd", anchor: .bottom) }
            .onAppear { if scroll.followLatest { proxy.scrollTo("captionEnd", anchor: .bottom) } }
            .overlay(alignment: .bottomTrailing) {
                if !scroll.followLatest {
                    Button {
                        scroll.followLatest = true; proxy.scrollTo("captionEnd", anchor: .bottom)
                    } label: { Label("回到最新", systemImage: "arrow.down") }
                        .buttonStyle(.borderedProminent).padding(8)
                }
            }
        }
    }
}

@main struct MeetingRecorderApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("captionFontSize") private var captionFontSize = 16.0
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var recorder = Recorder()
    @StateObject private var ui = RecorderUIState()

    private var settingsLocked: Bool { recorder.recording || recorder.busy }
    private var modelNeedsAttention: Bool {
        recorder.captionsEnabled && !recorder.recording && !recorder.busy &&
        recorder.captionModelLocale == recorder.captionLocale &&
        (recorder.captionModelState == .missing || recorder.captionModelState == .unsupported)
    }
    private var issueSection: String? {
        guard !recorder.recording, !recorder.busy else { return nil }
        let text = recorder.message
        if ["保存目录", "保存位置", "磁盘"].contains(where: { text.contains($0) }) &&
            ["失败", "无法", "不存在", "不可用", "不足"].contains(where: { text.contains($0) }) { return "storage" }
        if text.hasPrefix("启动失败") { return text.contains("模型") || text.contains("字幕") ? "captions" : "audio" }
        return nil
    }
    private func openSettings(_ section: String) { ui.settingsSection = section; ui.settingsVisible = true }

    var body: some Scene {
        Window("会议录音", id: "recorder") {
            VStack(spacing: 16) {
                header
                if modelNeedsAttention || issueSection != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(modelNeedsAttention ? recorder.captionModelState.message : "录音配置需要检查，请在设置中处理。")
                            .font(.callout).lineLimit(2)
                        Spacer(minLength: 8)
                        Button("前往设置") { openSettings(issueSection ?? "captions") }
                    }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 18) {
                    meter("我的麦克风", value: recorder.mic, track: "microphone", paused: recorder.micPaused)
                    Divider().frame(height: 20)
                    meter("系统声音", value: recorder.system, track: "system", paused: recorder.systemPaused)
                }.padding(.horizontal, 12).padding(.vertical, 10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                captionsPanel.layoutPriority(1)
                footer
            }
            .padding(20)
            .frame(minWidth: 680, minHeight: 560)
            .background(RecordingWindowHook(delegate: delegate))
            .onAppear { delegate.recorder = recorder; recorder.checkRecovery() }
            .sheet(isPresented: $recorder.libraryVisible) { libraryView }
            .sheet(isPresented: $ui.speakersVisible) {
                SpeakerNamesView(controller: recorder.speakerRecognition, locked: recorder.busy)
            }
            .sheet(isPresented: $ui.playbackVisible) {
                if let audio = recorder.currentAudio {
                    RecordingPlaybackView(audio: audio, title: recorder.displayTitle)
                }
            }
            .task(id: recorder.captionLocale) { await recorder.refreshCaptionModel() }
            .onChange(of: scenePhase) {
                if scenePhase == .active { Task { await recorder.refreshCaptionModel() } }
            }
        }.defaultSize(width: 860, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于会议录音") {
                    let credits = NSMutableAttributedString(string: "作者：")
                    credits.append(NSAttributedString(string: "@nalansitan", attributes: [
                        .link: URL(string: "https://github.com/nalansitan")!
                    ]))
                    credits.append(NSAttributedString(string: "\nApache License 2.0 · "))
                    credits.append(NSAttributedString(string: "项目主页", attributes: [
                        .link: URL(string: "https://github.com/nalansitan/macos-meeting-recorder")!
                    ]))
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().scaledToFit().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 8) {
                TextField("会议名称（可选）", text: $recorder.meetingTitle)
                    .font(.title2.bold()).textFieldStyle(.plain)
                    .accessibilityLabel("会议名称")
                    .onChange(of: recorder.meetingTitle) { recorder.titleChanged() }
                    .disabled(recorder.busy)
                HStack(spacing: 8) {
                    Circle().fill(recorder.recording ? (recorder.paused ? Color.orange : .red) : .secondary)
                        .frame(width: 6, height: 6)
                    Text(recorder.lifecycle)
                    if recorder.recording && recorder.echoCancellationActive {
                        Text("回声消除已开").foregroundStyle(.secondary)
                    }
                }.font(.caption)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 10) {
                Text(String(format: "%02d:%02d:%02d", Int(recorder.elapsed) / 3600, Int(recorder.elapsed) / 60 % 60, Int(recorder.elapsed) % 60))
                    .font(.title2.monospacedDigit())
                HStack(spacing: 8) {
                    Button { Task { await recorder.newRecording() } } label: {
                        Label("新建录音", systemImage: "plus")
                    }.disabled(recorder.busy)
                    Button { recorder.showLibrary() } label: {
                        Label("历史录音", systemImage: "clock")
                    }.help("查看已保存录音、改名或恢复草稿")
                    Button { openSettings("audio") } label: {
                        Label("设置", systemImage: "gearshape")
                    }.keyboardShortcut(",", modifiers: .command)
                        .popover(isPresented: $ui.settingsVisible, arrowEdge: .top) { settingsPanel }
                }.controlSize(.small)
            }
        }
    }

    private var captionsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("实时字幕", systemImage: "captions.bubble").font(.headline)
                Button("标注说话人") { ui.speakersVisible = true }.controlSize(.small)
                Spacer()
                Text("字号").font(.caption).foregroundStyle(.secondary)
                Slider(value: $captionFontSize, in: 12...36, step: 1)
                    .frame(width: 90).accessibilityLabel("字幕字号")
                Text("\(Int(captionFontSize))").font(.caption.monospacedDigit()).frame(width: 22)
                Button { captionFontSize = 16 } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless).help("恢复默认字号").accessibilityLabel("恢复默认字号")
                    .disabled(captionFontSize == 16)
            }
            Divider()
            if recorder.captionText.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: recorder.captionsEnabled ? "waveform" : "captions.bubble")
                        .font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(recorder.captionsEnabled ? (recorder.recording ? "正在聆听，确认后的字幕会显示在这里" : "开始录音后，字幕会显示在这里") : "实时字幕已关闭")
                        .foregroundStyle(.secondary)
                    if !recorder.recording {
                        Button("字幕设置") { openSettings("captions") }.buttonStyle(.borderless)
                    }
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CaptionTranscriptView(text: recorder.captionText, fontSize: captionFontSize, folder: recorder.folder)
                    .equatable()
            }
            SpeakerStatusView(controller: recorder.speakerRecognition)
            Divider()
            HStack {
                Text(recorder.captionsEnabled ? "仅展示最近 \(CaptionPresentation.retainedFinalCount) 条 · 完整记录见字幕文件" : "可在设置中开启离线实时字幕")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(recorder.recording ? recorder.captionStatus : "本地字幕 · 可标注说话人姓名")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .help(recorder.captionStatus)
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.quaternary) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: recorder.lifecycle.contains("失败") ? "exclamationmark.circle" : "info.circle")
                    .foregroundStyle(.secondary)
                Text(recorder.modelDownloadActive ? "正在下载并安装离线模型……" : (recorder.message.components(separatedBy: "\n").first ?? recorder.message))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("详情") { ui.detailsVisible = true }.buttonStyle(.borderless)
                    .popover(isPresented: $ui.detailsVisible) {
                        ScrollView { Text(recorder.message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                            .frame(width: 520, height: 220)
                    }
            }
            HStack(spacing: 10) {
                if recorder.recording {
                    Button(recorder.paused ? "继续录音" : "暂停录音") { recorder.togglePause() }
                    Button("结束并保存") { Task { await recorder.stop() } }.buttonStyle(.borderedProminent)
                } else if recorder.folder == nil {
                    Button("开始录音") { Task { await recorder.start() } }.buttonStyle(.borderedProminent)
                } else {
                    Button(recorder.lifecycle == "保存失败" ? "重试保存" : (recorder.lifecycle.contains("字幕异常") ? "重试生成字幕" : "保存录音")) { Task { await recorder.export() } }
                    Button { ui.playbackVisible = true } label: { Label("播放录音", systemImage: "play.circle") }
                        .disabled(recorder.currentAudio == nil)
                }
                if recorder.busy { ProgressView().controlSize(.small) }
                Spacer()
                Menu("更多") {
                    Button("查看录音文件") { if let url = recorder.folder { NSWorkspace.shared.open(url) } }
                        .disabled(recorder.folder == nil)
                    if recorder.folder != nil {
                        Divider()
                        Button(recorder.recording ? "放弃本次录音…" : "移到废纸篓…", role: .destructive) { Task { await recorder.removeRecording() } }
                    }
                }.fixedSize()
            }.disabled(recorder.busy).controlSize(.large)
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("录音设置").font(.title2.bold())
                Spacer()
                Button("完成") { ui.settingsVisible = false }.keyboardShortcut(.cancelAction)
            }
            if settingsLocked {
                Label("当前正在录音或处理，采集设置暂不可修改。字幕字号仍可在主界面调整。", systemImage: "lock")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        GroupBox("声音与回声消除") {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("麦克风", selection: $recorder.microphone) {
                                    Text("系统默认输入").tag("")
                                    ForEach(recorder.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                                }.disabled(settingsLocked)
                                Toggle("软件回声消除（实验性）", isOn: $recorder.echoCancellationEnabled)
                                    .disabled(settingsLocked)
                                Text(recorder.echoCancellationEnabled
                                     ? "在本应用内消除外放回声，仅影响录音和字幕，字幕额外延迟约 160 毫秒。首次使用建议先在测试会议确认双方收音。"
                                     : "默认关闭。外放时可开启软件处理以减少重复收音；戴耳机时通常无需开启。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(8)
                        }.id("audio")
                        GroupBox("离线实时字幕") {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("开启实时字幕", isOn: $recorder.captionsEnabled).disabled(settingsLocked)
                                Picker("识别语言", selection: $recorder.captionLocale) {
                                    Text("普通话（简体）").tag("zh_CN")
                                    Text("中文（繁体）").tag("zh_TW")
                                    Text("英语").tag("en_US")
                                    Text("粤语").tag("yue_CN")
                                }.disabled(settingsLocked || !recorder.captionsEnabled)
                                HStack {
                                    Text(recorder.captionModelLocale == recorder.captionLocale ? recorder.captionModelState.message : CaptionModelState.checking.message)
                                        .font(.callout).foregroundStyle(.secondary)
                                    Spacer()
                                    if recorder.modelDownloadActive {
                                        ProgressView().controlSize(.small)
                                    } else if recorder.captionModelLocale == recorder.captionLocale && recorder.captionModelState == .missing {
                                        Button("下载模型") { Task { await recorder.downloadCaptionModel() } }.disabled(settingsLocked)
                                    }
                                    Button("刷新") { Task { await recorder.refreshCaptionModel() } }.disabled(settingsLocked)
                                }
                                if let progress = recorder.modelDownloadProgress { ProgressView(progress) }
                                if !recorder.modelDownloadError.isEmpty {
                                    Text(recorder.modelDownloadError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                                }
                                Text("仅下载模型时联网，录音与识别均在本机完成。可另行开启说话人识别并标注姓名。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(8)
                        }.id("captions")
                        SpeakerSettingsView(controller: recorder.speakerRecognition, locked: settingsLocked, download: {
                            Task { await recorder.downloadSpeakerModel() }
                        }, importModels: {
                            Task { await recorder.importSpeakerModel() }
                        }).id("speakers")
                        GroupBox("录音保存位置") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(recorder.recordingRoot.path).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Button("更改位置…") { recorder.chooseSaveLocation() }
                                    Button("恢复默认") { recorder.resetSaveLocation() }.disabled(recorder.usesDefaultLocation)
                                }.disabled(settingsLocked)
                                Text("结束后自动生成 M4A 音频，开启字幕时另存同名 SRT。位置设置仅影响新录音。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }.id("storage")
                    }.padding(4)
                }
                .onAppear { proxy.scrollTo(ui.settingsSection, anchor: .top) }
                .onChange(of: ui.settingsSection) { proxy.scrollTo(ui.settingsSection, anchor: .top) }
            }
        }.padding(20).frame(width: 540, height: 600)
            .onAppear { if !settingsLocked { recorder.refreshDevices() } }
    }

    private var libraryView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("历史录音").font(.title2.bold())
                Spacer()
                Button("从文件夹打开…") { recorder.chooseRecording() }.disabled(recorder.busy)
                Button("完成") { recorder.libraryVisible = false }
            }
            Text(recorder.busy ? "当前录音正在保存，可先浏览历史记录，完成后可打开或改名。" : "打开录音后可修改顶部会议名称，再点击“保存录音”。草稿可恢复保存；列表包括当前及之前使用过的保存位置。")
                .font(.caption).foregroundStyle(.secondary)
            if recorder.entries.isEmpty { Text("暂无录音；也可从文件夹打开已有录音。") }
            List(recorder.entries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title.isEmpty ? "未命名录音" : entry.title).font(.headline)
                        Text("\(entry.status) · \(Int(entry.duration) / 60) 分 \(Int(entry.duration) % 60) 秒").font(.caption)
                        Text(entry.folder.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(entry.needsAttention ? "恢复保存…" : "打开 / 改名") { Task { await recorder.openEntry(entry) } }
                    Button("移到废纸篓…", role: .destructive) { Task { await recorder.removeRecording(entry.folder) } }
                }.buttonStyle(.borderless)
                    .accessibilityElement(children: .contain)
                    .disabled(recorder.busy)
            }
            Text(recorder.message).font(.callout).textSelection(.enabled)
        }.padding(24).frame(width: 720, height: 480)
    }

    private func meter(_ label: String, value: Float, track: String, paused: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(paused ? .secondary : .primary)
                .fixedSize()
            ProgressView(value: Double(value)).tint(value > 0.95 ? .orange : .blue)
            Button { recorder.toggleTrack(track) } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill").font(.caption2)
            }.buttonStyle(.borderless)
                .accessibilityLabel("\(label)：\(paused ? "继续此路" : "暂停此路")")
                .disabled(!recorder.recording || recorder.busy)
                .help(paused ? "继续保存此路声音" : "暂停保存此路声音，不影响另一条音轨与计时")
        }.frame(maxWidth: .infinity)
    }
}
