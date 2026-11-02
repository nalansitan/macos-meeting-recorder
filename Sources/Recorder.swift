import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

// Finder-launched apps often have a minimal PATH. Search common package-manager
// locations as well, while respecting an explicitly inherited PATH.
func recordingExecutable(_ name: String) -> URL? {
    let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin"]
    var candidates = directories.filter { $0.hasPrefix("/") }
        .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name) }
    // Apple's python3 may be a developer-tools launcher on a fresh Mac. Prefer
    // an installed interpreter before that fallback, even with Finder's PATH.
    if name == "python3" {
        candidates.removeAll { $0.path == "/usr/bin/python3" }
        candidates.append(URL(fileURLWithPath: "/usr/bin/python3"))
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

@MainActor final class Recorder: ObservableObject {
    @Published var recording = false
    @Published var paused = false
    @Published var micPaused = false
    @Published var systemPaused = false
    @Published var busy = false
    @Published var message = "准备就绪。开始后会分别录下麦克风和电脑播放的声音。"
    @Published var elapsed = 0.0
    @Published var mic: Float = 0
    @Published var system: Float = 0
    @Published var folder: URL?
    @Published var meetingTitle = ""
    @Published var microphone = ""
    @Published var echoCancellationEnabled = false {
        didSet { preferences.set(echoCancellationEnabled, forKey: "echoCancellationEnabled") }
    }
    @Published private(set) var echoCancellationActive = false
    @Published var devices: [AVCaptureDevice] = []
    let speakerRecognition = SpeakerController()
    @Published var captionsEnabled = true
    @Published var captionLocale = "zh_CN"
    @Published var captionText = ""
    @Published var captionStatus = "识别只使用本机模型，不使用云端识别。"
    @Published private(set) var captionModelState: CaptionModelState = .checking
    @Published private(set) var captionModelLocale = ""
    @Published private(set) var modelDownloadProgress: Progress?
    @Published private(set) var modelDownloadActive = false
    @Published private(set) var modelDownloadError = ""
    private var modelCheckID = UUID()
    private let preferences: UserDefaults
    // A single presentation boundary also lets lifecycle tests exercise cancellation without opening dialogs.
    var presentAlert: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    var moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    @Published private(set) var saveParent: URL
    private static let saveParentKey = "recordingParentDirectory"
    private static var defaultParent: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    }
    var recordingRoot: URL { saveParent.appendingPathComponent("会议录音", isDirectory: true) }
    var usesDefaultLocation: Bool { saveParent == Self.defaultParent }
    @Published var libraryVisible = false
    @Published var entries: [RecordingEntry] = []
    @Published var lifecycle = "准备录音"
    private var attention = false
    private var sessionState = "draft"
    private var loadingEntry = false
    private var knownRoots: [String] {
        get { preferences.stringArray(forKey: "recordingLibraryRoots") ?? [] }
        set { preferences.set(newValue, forKey: "recordingLibraryRoots") }
    }

    var displayTitle: String { meetingTitle.isEmpty ? "未命名录音" : meetingTitle }
    var currentAudio: URL? { folder.flatMap { try? RecordingEntry.read($0).audio } }

    private func rememberRoot(_ root: URL) {
        knownRoots = Array(Set(knownRoots + [root.standardizedFileURL.path]))
    }

    func refreshLibrary() {
        let roots = Set(knownRoots + [recordingRoot.path, Self.defaultParent.appendingPathComponent("会议录音").path])
        entries = RecordingLibrary.entries(roots: roots.map { URL(fileURLWithPath: $0) })
    }

    func showLibrary() { refreshLibrary(); libraryVisible = true }

    func titleChanged() {
        guard !loadingEntry, let folder else { return }
        if let item = try? RecordingEntry.read(folder), item.title == meetingTitle { return }
        attention = true
        if !recording { sessionState = "draft"; lifecycle = "草稿待保存" }
        do { try RecordingLibrary.writeNote(folder: folder, title: meetingTitle, state: sessionState) }
        catch { message = "会议名称尚未保存：\(error.localizedDescription)" }
    }

    private func persist(_ state: String) throws {
        guard let folder else { return }
        try RecordingLibrary.writeNote(folder: folder, title: meetingTitle, state: state)
        sessionState = state
    }

    private func clearSession() {
        loadingEntry = true
        speakerRecognition.open(nil)
        folder = nil; meetingTitle = ""; captionText = ""; elapsed = 0
        attention = false; lifecycle = "准备录音"; sessionState = "draft"
        micPaused = false; systemPaused = false
        captionStatus = "识别只使用本机模型，不使用云端识别。"
        loadingEntry = false
    }

    func prepareToLeave(_ destination: String) async -> Bool {
        guard !busy else {
            message = modelDownloadActive ? "正在准备离线模型，完成后可继续。" : "正在处理当前录音，完成后可继续。"
            return false
        }
        guard recording || attention else { return true }
        let alert = NSAlert()
        alert.messageText = "\(destination)前，如何处理当前录音？"
        alert.informativeText = "“\(displayTitle)”时长 \(Int(elapsed) / 60) 分 \(Int(elapsed) % 60) 秒。" + (recording ? "继续会结束本次录制。" : "当前录音尚未完成保存。") + "草稿保留在本机，可在录音记录中稍后保存。"
        alert.addButton(withTitle: "保存并继续")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "保留草稿并继续")
        switch presentAlert(alert) {
        case .alertFirstButtonReturn:
            if recording { return await stop() }
            await export()
            return !attention
        case .alertThirdButtonReturn:
            if recording { return await stop(save: false) }
            do { try persist("draft"); return true }
            catch { message = "无法保留草稿：\(error.localizedDescription)"; return false }
        default: return false
        }
    }

    func newRecording() async {
        guard await prepareToLeave("新建录音") else { return }
        clearSession()
        message = "准备就绪，点击开始录音。"
    }

    func openEntry(_ entry: RecordingEntry) async {
        if folder == entry.folder { libraryVisible = false; return }
        guard await prepareToLeave("打开另一场录音") else { return }
        do {
            let item = try RecordingEntry.read(entry.folder)
            try RecordingLibrary.withExclusiveAccess(item.folder) {}
            clearSession(); loadingEntry = true
            folder = item.folder; meetingTitle = item.title; elapsed = item.duration
            speakerRecognition.open(item.folder)
            attention = item.needsAttention; lifecycle = item.status
            sessionState = attention ? "draft" : "saved"
            loadingEntry = false
            rememberRoot(item.folder.deletingLastPathComponent())
            message = item.needsAttention ? "原始录音已保留，可保存录音或移到废纸篓。" : "已打开录音，可播放或查看文件。"
            libraryVisible = false
        } catch { message = "无法打开录音：\(error.localizedDescription)" }
    }

    func removeRecording(_ target: URL? = nil) async {
        guard !busy, let target = target ?? folder else { return }
        let isCurrent = target == folder
        let isLive = isCurrent && recording
        let title = (try? RecordingEntry.read(target).title) ?? ""
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = isLive ? "放弃本次录音？" : "将这场录音移到废纸篓？"
        alert.informativeText = "“\(title.isEmpty ? "未命名录音" : title)”的音频、字幕和原始片段将一起移到废纸篓，可从废纸篓恢复。" + (isLive ? "本次录制将结束。" : "")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: isLive ? "放弃录音" : "移到废纸篓").hasDestructiveAction = true
        guard presentAlert(alert) == .alertSecondButtonReturn else { return }
        if isLive, !(await stop(save: false)) { return }
        do {
            _ = try RecordingEntry.read(target)
            try RecordingLibrary.withExclusiveAccess(target) {
                try moveToTrash(target)
            }
            if isCurrent { clearSession() }
            message = "录音已移到废纸篓，可在 Finder 中恢复。"
            refreshLibrary()
        } catch { message = "未能移到废纸篓，录音仍保留：\(error.localizedDescription)" }
    }

    func checkRecovery() {
        refreshLibrary()
        if entries.contains(where: { $0.needsAttention }) {
            message = "发现未完成的录音，可在录音记录中恢复保存或移到废纸篓。"
            libraryVisible = true
        }
    }

    private var stream: SCStream?
    private var sink: AudioSink?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var captions: (any CaptionSession)?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        echoCancellationEnabled = preferences.bool(forKey: "echoCancellationEnabled")
        if let path = preferences.string(forKey: Self.saveParentKey), path.hasPrefix("/") {
            saveParent = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveParent = Self.defaultParent
        }
        speakerRecognition.onChange = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            if !self.recording { self.refreshNamedCaptions() }
        }
        refreshDevices()
    }

    private func refreshNamedCaptions() {
        guard let folder, !speakerRecognition.speakers.isEmpty,
              let data = try? String(contentsOf: folder.appendingPathComponent("captions.jsonl"), encoding: .utf8) else { return }
        captionText = data.split(separator: "\n").suffix(CaptionPresentation.retainedFinalCount).flatMap { line -> [String] in
            guard let cue = try? JSONDecoder().decode(CaptionCue.self, from: Data(line.utf8)) else { return [] }
            return speakerRecognition.captionLines(cue)
        }.joined(separator: "\n")
    }

    func chooseSaveLocation() {
        guard !recording, !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveParent
        panel.prompt = "选择保存位置"
        panel.message = "选择父目录，应用会在其中创建“会议录音”文件夹。此设置仅影响之后的新录音。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RecordingStorage.prepareRoot(parent: url)
            rememberRoot(recordingRoot)
            saveParent = url.standardizedFileURL
            rememberRoot(recordingRoot)
            preferences.set(saveParent.path, forKey: Self.saveParentKey)
            message = "保存位置已更新，新录音将保存在：\(recordingRoot.path)"
        } catch {
            message = "无法使用所选保存位置：\(error.localizedDescription)"
        }
    }

    func resetSaveLocation() {
        guard !recording, !busy else { return }
        rememberRoot(recordingRoot)
        saveParent = Self.defaultParent
        preferences.removeObject(forKey: Self.saveParentKey)
        message = "已恢复默认保存位置：\(recordingRoot.path)"
    }

    func downloadSpeakerModel() async {
        guard !busy, !recording else { return }
        busy = true
        defer { busy = false }
        await speakerRecognition.download()
    }

    func importSpeakerModel() async {
        guard !busy, !recording else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导入模型"
        panel.message = "选择包含两个完整 .mlmodelc 模型目录的文件夹。验证通过后替换本地模型，人员库保留。"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        busy = true
        defer { busy = false }
        await speakerRecognition.importModels(from: source)
    }

    func refreshDevices() {
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    func refreshCaptionModel() async {
        guard !recording, !busy else { return }
        let identifier = captionLocale
        let checkID = UUID()
        modelCheckID = checkID
        captionModelLocale = identifier
        captionModelState = .checking
        modelDownloadError = ""
        let state: CaptionModelState
        if #available(macOS 26.0, *) { state = await SpeechModelAssets.state(for: identifier) }
        else { state = .unsupported }
        guard modelCheckID == checkID, captionLocale == identifier, !busy, !recording else { return }
        captionModelState = state
    }

    func downloadCaptionModel() async {
        guard !recording, !busy, captionModelLocale == captionLocale,
              captionModelState == .missing else { return }
        guard #available(macOS 26.0, *) else { return }
        let identifier = captionLocale
        modelCheckID = UUID()
        busy = true; modelDownloadActive = true; modelDownloadError = ""
        defer { busy = false; modelDownloadActive = false; modelDownloadProgress = nil }
        do {
            try await SpeechModelAssets.download(identifier) { self.modelDownloadProgress = $0 }
            captionModelState = await SpeechModelAssets.state(for: identifier)
            if captionModelState != .installed { throw problem("模型尚未就绪，请稍后刷新状态。") }
            message = "离线模型已就绪，可以断网录音和识别。"
        } catch {
            captionModelState = await SpeechModelAssets.state(for: identifier)
            modelDownloadError = "下载未完成：\(error.localizedDescription)"
        }
    }

    func start() async {
        guard !busy, !recording, folder == nil else { return }
        busy = true
        defer { busy = false }
        do {
            // Check offline assets before requesting capture or creating a recording.
            if captionsEnabled {
                guard #available(macOS 26.0, *) else { throw problem("实时字幕需要 macOS 26 或更新版本；可关闭字幕后仅录音。") }
                _ = try await OfflineCaptionSession.checkLocale(captionLocale)
            }
            try RecordingStorage.prepareRoot(parent: saveParent)
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw problem("请在系统设置 → 隐私与安全性 → 麦克风中允许“会议录音”，然后重新打开应用。")
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw problem("没有可用于系统音频采集的显示器") }
            let root = recordingRoot
            let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let directory = root.appendingPathComponent(date.string(from: Date()) + "-" + UUID().uuidString.prefix(6))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            rememberRoot(root)
            let output = try AudioSink(folder: directory, softwareEchoCancellation: echoCancellationEnabled)
            folder = directory; elapsed = 0
            sink = output
            attention = true; sessionState = "draft"
            try persist("draft")
            try output.checkpoint()
            output.onFailure = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.recording else { return }
                    await self.stop(error: error)
                }
            }
            captionText = ""
            try await speakerRecognition.start(folder: directory)
            if captionsEnabled, #available(macOS 26.0, *) {
                let session = try OfflineCaptionSession(folder: directory, locale: Locale(identifier: captionLocale)) { [weak self] text, status in
                    self?.captionText = text; self?.captionStatus = status
                }
                if speakerRecognition.enabled {
                    session.speakerRevision = { [weak self] in self?.speakerRecognition.revision ?? 0 }
                    session.speakerLines = { [weak self] cue in
                        self?.speakerRecognition.captionLines(cue) ?? [cue.text]
                    }
                }
                try await session.start()
                captions = session
                output.onAudio = session.audioReceiver
                captionStatus = "纯离线识别 · 按音源区分我 / 会议对方"
            }
            let captionReceiver = output.onAudio
            let speakerReceiver = speakerRecognition.audioReceiver
            output.onAudio = { pcm, track, time in
                captionReceiver?(pcm, track, time)
                speakerReceiver?(pcm, track, time)
            }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.captureMicrophone = true
            if !microphone.isEmpty { config.microphoneCaptureDeviceID = microphone }
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.width = 2; config.height = 2
            config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let capture = SCStream(filter: filter, configuration: config, delegate: output)
            try capture.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try capture.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
            stream = capture
            try await capture.startCapture()
            guard output.queue.sync(execute: { !output.finished }) else { throw problem("采集启动期间音频写入失败，原始片段已保留。") }
            echoCancellationActive = echoCancellationEnabled
            lifecycle = "录音中"
            recording = true; paused = false; micPaused = false; systemPaused = false; elapsed = 0
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "保存会议录音")
            message = echoCancellationActive
                ? "正在本机录音 · 软件回声消除已开启，处理后的麦克风声音用于录音和字幕。"
                : "正在本机录音。系统音轨包含其他应用播放的声音；建议戴耳机，避免麦克风重复收音。"
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let sink = self.sink else { return }
                    let values = sink.queue.sync {
                        let values = sink.levels
                        sink.levels = (0, 0)
                        return (values.0, values.1, sink.elapsed)
                    }
                    self.mic = values.0; self.system = values.1
                    self.elapsed = values.2
                }
            }
        } catch {
            echoCancellationActive = false
            if let capture = stream { try? await capture.stopCapture() }
            if let output = sink { output.queue.sync { try? output.finish(error: error.localizedDescription) } }
            await speakerRecognition.finish()
            await captions?.finish(); captions = nil
            stream = nil; sink = nil
            lifecycle = folder == nil ? "准备录音" : "草稿待保存"
            message = "启动失败：\(error.localizedDescription)"
        }
    }

    func togglePause() {
        guard recording, !busy, let sink else { return }
        do {
            let value = !paused
            elapsed = try sink.queue.sync {
                try sink.setPaused(value)
                return sink.elapsed
            }
            paused = value
            lifecycle = value ? "已暂停" : "录音中"
            message = value ? "已暂停，计时已停止，两路声音均不保存。继续后会接着录制，不保留暂停空白。" : "继续录音，接续暂停前的时间。"
        } catch { Task { await stop(error: error.localizedDescription) } }
    }

    func toggleTrack(_ track: String) {
        guard recording, !busy, let sink else { return }
        let value = track == "microphone" ? !micPaused : !systemPaused
        do {
            try sink.queue.sync { try sink.setTrackPaused(track, value) }
            if track == "microphone" { micPaused = value; mic = 0 }
            else { systemPaused = value; system = 0 }
        } catch { Task { await stop(error: error.localizedDescription) } }
    }

    @discardableResult func stop(error: String? = nil, save: Bool = true) async -> Bool {
        guard let capture = stream else { return false }
        stream = nil
        busy = true
        defer { busy = false }
        timer?.invalidate(); timer = nil
        var failure = error
        echoCancellationActive = false
        do { try await capture.stopCapture() } catch { failure = failure ?? error.localizedDescription }
        if let output = sink {
            do {
                elapsed = try output.queue.sync {
                    try output.finish(error: failure)
                    return output.elapsed
                }
            }
            catch { failure = failure ?? error.localizedDescription }
        }
        lifecycle = save ? "正在保存" : "正在保留草稿"
        message = "录音已停止，正在确认最后的字幕……"
        await speakerRecognition.finish()
        await captions?.finish(); captions = nil
        sink = nil; recording = false; paused = false; mic = 0; system = 0
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        // Even if capture shutdown reports an error, recover the saved fragments.
        // Keep busy until the mixed file has actually been produced.
        guard let folder else { message = "没有可导出的录音目录"; return false }
        if !save {
            do {
                try persist("draft"); attention = true; lifecycle = "草稿待保存"
                message = "草稿已保留在本机，可在录音记录中稍后保存。"
                return true
            } catch { lifecycle = "保存失败"; message = "无法保留草稿：\(error.localizedDescription)"; return false }
        }
        let saved = await exportSavedRecording(folder)
        if let failure { message += "\n采集结束提示：\(failure)" }
        return saved
    }

    func chooseRecording() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择含有 meeting.json 的录音文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entry = try RecordingEntry.read(url)
            Task { await openEntry(entry) }
        } catch { message = "无法打开录音：\(error.localizedDescription)" }
    }

    func export() async {
        guard let folder, !recording, !busy else { return }
        busy = true
        defer { busy = false }
        _ = await exportSavedRecording(folder)
    }

    private func exportSavedRecording(_ folder: URL) async -> Bool {
        let title = meetingTitle
        lifecycle = "正在保存"
        attention = true
        do { try persist("failed") }
        catch { message = "无法写入录音状态：\(error.localizedDescription)"; lifecycle = "保存失败"; return false }
        message = "正在自动混音并保存录音，请等待完成；长录音可能需要几分钟……"
        guard let script = Bundle.main.url(forResource: "export", withExtension: "py") else {
            message = "导出失败：应用缺少导出脚本，请重新安装。原始片段已保留。"
            attention = true; lifecycle = "保存失败"
            return false
        }
        let result: (Bool, String) = await Task.detached {
            do {
                guard let python = recordingExecutable("python3") else {
                    return (false, "自动保存失败：未找到 Python 3，请安装后重试。原始片段已保留。")
                }
                guard let ffmpeg = recordingExecutable("ffmpeg") else {
                    return (false, "自动保存失败：未找到 FFmpeg，请安装后重试。原始片段已保留。")
                }
                let process = Process()
                process.executableURL = python
                process.arguments = [script.path, folder.path, "--title", title, "--ffmpeg", ffmpeg.path]
                let pipe = Pipe(); process.standardError = pipe; process.standardOutput = pipe
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                try? ("\(Date()) exit=\(process.terminationStatus)\n" + output).write(
                    to: folder.appendingPathComponent("export.log"), atomically: true, encoding: .utf8)
                if process.terminationStatus != 0 {
                    return (false, "自动保存失败，原始片段已保留。可点击“重试保存”重试：\(output)")
                }
                let reportData = try Data(contentsOf: folder.appendingPathComponent("export.json"))
                let report = try JSONSerialization.jsonObject(with: reportData) as? [String: Any]
                guard let filename = report?["file"] as? String,
                      URL(fileURLWithPath: filename).lastPathComponent == filename,
                      FileManager.default.fileExists(atPath: folder.appendingPathComponent(filename).path) else {
                    return (false, "导出未生成录音文件，请点击“重试保存”重试。")
                }
                let subtitleFailed = report?["subtitle_error"] as? String != nil
                return (true, "\(subtitleFailed ? "音频已保存，字幕导出失败" : "已自动保存")：\(folder.appendingPathComponent(filename).path)\n" + output)
            } catch { return (false, "自动保存失败，原始片段已保留：\(error.localizedDescription)") }
        }.value
        message = result.1
        attention = !result.0
        if result.0 {
            do { try persist("saved") }
            catch { attention = true; message += "\n录音状态写入失败：\(error.localizedDescription)" }
        }
        lifecycle = attention ? "保存失败" : ((try? RecordingEntry.read(folder).status) ?? "已保存")
        refreshLibrary()
        return !attention
    }
}
