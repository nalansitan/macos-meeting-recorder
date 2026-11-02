import AVFoundation
import Foundation
import Speech

enum CaptionPresentation {
    static let retainedFinalCount = 300
}

// A task group would still wait for an uncooperative Speech framework task on exit.
// Resolve independently so cancellation of the system service cannot hold up saving.
@MainActor final class CaptionTaskDeadline {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timer: Task<Void, Never>?

    private func resolve(_ completed: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel(); timer = nil
        continuation.resume(returning: completed)
    }

    static func wait(for tasks: [Task<Void, Never>], timeout: Duration = .seconds(30)) async -> Bool {
        let deadline = CaptionTaskDeadline()
        return await withCheckedContinuation { continuation in
            deadline.continuation = continuation
            deadline.timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                deadline.resolve(false)
            }
            Task {
                for task in tasks { await task.value }
                deadline.resolve(true)
            }
        }
    }
}

struct CaptionPreview {
    private(set) var text = ""
    private var changedAt = 0.0

    mutating func update(_ text: String, now: Double) {
        if self.text != text { self.text = text; changedAt = now }
    }

    func visible(at now: Double) -> String? {
        text.isEmpty || now - changedAt >= 8 ? nil : text
    }
}

@MainActor protocol CaptionSession: AnyObject {
    var audioReceiver: (AVAudioPCMBuffer, String, Double) -> Void { get }
    func finish() async
}

private struct CaptionPacket: @unchecked Sendable {
    // AudioSink creates a fresh buffer per callback and never mutates it after delivery.
    let buffer: AVAudioPCMBuffer
    let start: Double
}

// Only the analyzer's input iterator accesses this converter.
@available(macOS 26.0, *)
private final class CaptionConverter: @unchecked Sendable {
    let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var previousEnd: Double?
    private var nextOutputFrame: Int64?
    init(format: AVAudioFormat) { self.format = format }

    func input(_ packet: CaptionPacket) throws -> AnalyzerInput {
        let source = packet.buffer
        let discontinuity = converter?.inputFormat != source.format ||
            previousEnd.map({ abs($0 - packet.start) > 0.05 }) == true
        if discontinuity {
            converter = AVAudioConverter(from: source.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw problem("无法转换实时字幕音频格式") }
        previousEnd = packet.start + Double(source.frameLength) / source.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * format.sampleRate / source.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw problem("无法分配字幕音频缓冲区")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return source
        }
        if let error { throw error }
        guard status != .error, output.frameLength > 0 else { throw problem("实时字幕音频转换失败") }
        let frame = Int64((max(0, packet.start) * format.sampleRate).rounded())
        let startFrame = discontinuity ? max(frame, nextOutputFrame ?? frame) : (nextOutputFrame ?? frame)
        nextOutputFrame = startFrame + Int64(output.frameLength)
        // Resampling can round a buffer up by one frame. Keep contiguous converted
        // buffers on an integer sample clock so Speech never sees overlapping input.
        return AnalyzerInput(buffer: output, bufferStartTime: CMTime(value: startFrame, timescale: Int32(format.sampleRate)))
    }
}

@available(macOS 26.0, *)
private final class CaptionLane {
    let analyzer: SpeechAnalyzer
    let transcriber: SpeechTranscriber
    let detector: SpeechDetector
    let continuation: AsyncThrowingStream<CaptionPacket, Error>.Continuation
    let packets: AsyncThrowingStream<CaptionPacket, Error>
    var analysisTask: Task<Void, Never>?
    var resultTask: Task<Void, Never>?
    var timeoutFailure: (@MainActor () -> Void)?
    @MainActor var acceptsResults = true

    init(locale: Locale) {
        transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: false)
        analyzer = SpeechAnalyzer(modules: [detector, transcriber],
                                  options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        // Bounded buffering: a slow/failed recognizer must never accumulate a meeting in RAM.
        (packets, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(256))
    }

    func enqueue(_ buffer: AVAudioPCMBuffer, start: Double) {
        if case .dropped = continuation.yield(CaptionPacket(buffer: buffer, start: start)) {
            continuation.finish(throwing: problem("字幕处理跟不上音频，已停止此路识别；录音继续保存"))
        }
    }

    @MainActor func start(track: String, update: @escaping @MainActor (String, [CaptionCue]?, String?) -> Void) async throws {
        timeoutFailure = { update(track, nil, "识别失败：结束后等待字幕确认超过 30 秒，仅保留已确认文字") }
        guard await AssetInventory.status(forModules: [detector, transcriber]) == .installed else {
            throw problem("离线字幕模型未就绪；请先在录音前下载模型，再开始录音。录音中不会联网下载。")
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [detector, transcriber]) else {
            throw problem("无法取得系统离线识别音频格式")
        }
        try await analyzer.prepareToAnalyze(in: format)
        let transcriber = self.transcriber
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled, self?.acceptsResults == true else { break }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        // Group timestamped words/characters into readable subtitle cues.
                        var cues: [CaptionCue] = []
                        var words = ""
                        var tokens: [CaptionToken] = []
                        var begin = 0.0
                        var end = 0.0
                        for run in result.text.runs {
                            let piece = String(result.text[run.range].characters)
                            guard let time = run.audioTimeRange else {
                                words += piece
                                if !tokens.isEmpty { tokens[tokens.count - 1].text += piece }
                                continue
                            }
                            let nextEnd = CMTimeRangeGetEnd(time).seconds
                            if !tokens.isEmpty && (words.count + piece.count > 42 || nextEnd - begin > 6 || time.start.seconds - end > 0.8) {
                                cues.append(CaptionCue(track: track, start: begin, end: end, text: words, tokens: tokens))
                                words = ""; tokens = []
                            }
                            if tokens.isEmpty { begin = time.start.seconds }
                            tokens.append(CaptionToken(start: time.start.seconds, end: nextEnd, text: piece))
                            words += piece; end = nextEnd
                        }
                        if !tokens.isEmpty { cues.append(CaptionCue(track: track, start: begin, end: end, text: words, tokens: tokens)) }
                        if cues.isEmpty && !text.isEmpty {
                            cues = [CaptionCue(track: track, start: result.range.start.seconds,
                                               end: CMTimeRangeGetEnd(result.range).seconds, text: text)]
                        }
                        update(track, cues, nil)
                    } else { update(track, nil, text) }
                }
            } catch {
                if !Task.isCancelled, self?.acceptsResults == true { update(track, nil, "识别失败：\(error.localizedDescription)") }
            }
        }
        let analyzer = self.analyzer
        let packets = self.packets
        let converter = CaptionConverter(format: format)
        let resultWorker = resultTask
        analysisTask = Task.detached(priority: .userInitiated) {
            do {
                let last = try await analyzer.analyzeSequence(packets.map { try converter.input($0) })
                if Task.isCancelled { await analyzer.cancelAndFinishNow() }
                else if let last { try await analyzer.finalizeAndFinish(through: last) }
                else { resultWorker?.cancel(); await analyzer.cancelAndFinishNow() }
            } catch {
                if !Task.isCancelled { await update(track, nil, "识别失败：\(error.localizedDescription)") }
                await analyzer.cancelAndFinishNow()
            }
        }
    }

    @MainActor func finish() async {
        continuation.finish()
        let completed = await CaptionTaskDeadline.wait(for: [analysisTask, resultTask].compactMap { $0 })
        acceptsResults = false
        if !completed {
            timeoutFailure?()
            analysisTask?.cancel()
            resultTask?.cancel()
            let analyzer = self.analyzer
            Task.detached { await analyzer.cancelAndFinishNow() }
        }
        analysisTask = nil; resultTask = nil; timeoutFailure = nil
    }
}

@available(macOS 26.0, *)
@MainActor final class OfflineCaptionSession: CaptionSession {
    private let folder: URL
    private let locale: String
    private let journal: FileHandle
    private var lanes: [String: CaptionLane] = [:]
    private var errors: [String] = []
    private var ownsReservation = false
    private var finished = false
    private var previews: [String: CaptionPreview] = [:]
    private var refreshTask: Task<Void, Never>?
    private var lastDisplay = ""
    private var lastStatus = ""
    private var closed = false
    private var finalCues: [CaptionCue] = []
    var speakerLines: ((CaptionCue) -> [String])?
    var speakerRevision: (() -> Int)?
    private var cueRevision = 0
    private var renderedCueRevision = -1
    private var renderedSpeakerRevision = -1
    private var renderedLines: [String] = []
    private var finalLines: [String] {
        let revision = speakerRevision?() ?? 0
        if renderedCueRevision != cueRevision || renderedSpeakerRevision != revision {
            renderedLines = finalCues.flatMap { cue in
                speakerLines?(cue) ?? [(cue.track == "microphone" ? "我" : "会议对方") + "：" + cue.text]
            }
            renderedCueRevision = cueRevision; renderedSpeakerRevision = revision
        }
        return renderedLines
    }
    private let display: (String, String) -> Void

    static func checkLocale(_ identifier: String) async throws -> Locale {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw problem("此 Mac 不支持所选语言的系统离线识别")
        }
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(locale) else {
            throw problem("尚未安装 \(identifier) 离线模型。请点击“下载离线模型”，完成后再开始录音；录音中不会联网下载或使用云端识别。")
        }
        return locale
    }

    init(folder: URL, locale: Locale, display: @escaping (String, String) -> Void) throws {
        self.folder = folder; self.locale = locale.identifier; self.display = display
        let path = folder.appendingPathComponent("captions.jsonl")
        guard FileManager.default.createFile(atPath: path.path, contents: nil) else { throw problem("无法创建字幕记录") }
        journal = try FileHandle(forWritingTo: path)
        try status("running")
    }

    func start() async throws {
        do {
            // Reserving already-installed assets subscribes this app to the local model.
            // It does not request installation or permit any server transcription.
            ownsReservation = try await AssetInventory.reserve(locale: Locale(identifier: locale))
            for track in ["microphone", "system"] {
                let lane = CaptionLane(locale: Locale(identifier: locale))
                lanes[track] = lane
                try await lane.start(track: track) { [weak self] track, cues, preview in
                    self?.receive(track: track, cues: cues, preview: preview)
                }
            }
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    self?.refreshDisplay()
                }
            }
        } catch {
            errors.append(error.localizedDescription)
            await finish()
            throw error
        }
    }

    var audioReceiver: (AVAudioPCMBuffer, String, Double) -> Void {
        let lanes = self.lanes
        return { buffer, track, start in lanes[track]?.enqueue(buffer, start: start) }
    }

    private func receive(track: String, cues: [CaptionCue]?, preview: String?) {
        guard !closed else { return }
        let speaker = track == "microphone" ? "我" : "会议对方"
        do {
            if let cues {
                for cue in cues where !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard cue.start.isFinite, cue.end.isFinite, cue.end > cue.start else {
                        throw problem("系统返回了无效的字幕时间戳")
                    }
                    var data = try JSONEncoder().encode(cue); data.append(0x0a)
                    try journal.write(contentsOf: data)
                    finalCues.append(cue); cueRevision &+= 1
                }
                finalCues = Array(finalCues.suffix(CaptionPresentation.retainedFinalCount))
                previews[track] = nil
            } else if let preview {
                if preview.hasPrefix("识别失败：") {
                    errors.append("\(speaker)：\(preview)"); try status("failed")
                    previews[track] = nil
                } else if preview.isEmpty {
                    previews[track] = nil
                } else {
                    var pending = previews[track] ?? CaptionPreview()
                    pending.update("\(speaker)（识别中）：\(preview)", now: ProcessInfo.processInfo.systemUptime)
                    previews[track] = pending
                }
            }
        } catch {
            errors.append(error.localizedDescription)
            try? status("failed")
        }
    }

    private func refreshDisplay() {
        guard !closed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let live = ["microphone", "system"].compactMap { previews[$0]?.visible(at: now) }
        let text = (finalLines + live).joined(separator: "\n")
        let status = errors.last ?? "纯离线识别 · \(locale) · 按音源区分双方"
        guard text != lastDisplay || status != lastStatus else { return }
        lastDisplay = text; lastStatus = status
        display(text, status)
    }

    private func status(_ state: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["state": state, "locale": locale, "errors": errors], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("captions-status.json"), options: .atomic)
    }

    func finish() async {
        guard !finished else { return }
        finished = true
        await withTaskGroup(of: Void.self) { group in
            for lane in lanes.values { group.addTask { await lane.finish() } }
        }
        closed = true
        refreshTask?.cancel(); refreshTask = nil
        previews.removeAll()
        do {
            try journal.synchronize()
            try status(errors.isEmpty ? "completed" : "failed")
            try journal.close()
            display(finalLines.joined(separator: "\n"), errors.last ?? "离线识别已完成，字幕已确认。")
        } catch { display(finalLines.joined(separator: "\n"), "字幕保存失败：\(error.localizedDescription)") }
        lanes.removeAll()
        if ownsReservation { await AssetInventory.release(reservedLocale: Locale(identifier: locale)) }
    }
}
