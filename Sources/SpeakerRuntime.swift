import AppKit
import AVFoundation
import CoreML
import CryptoKit
import Foundation
import SwiftUI
#if canImport(FluidAudio)
import FluidAudio
#endif

@MainActor final class SpeakerController: ObservableObject {
    @Published var enabled = UserDefaults.standard.bool(forKey: "speakerRecognitionEnabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "speakerRecognitionEnabled") }
    }
    @Published private(set) var ready = false
    @Published private(set) var downloading = false
    @Published private(set) var importing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "未下载说话人模型"
    @Published private(set) var speakers: [MeetingSpeaker] = []
    @Published private(set) var people: [VoicePerson] = []
    private var modelID = ""
    private var libraryReadable = true
    private var folder: URL?
    private var turns: [SpeakerTurn] = []
    private var matchEvidence: [String: SpeakerMatchEvidence] = [:]
    private var worker: SpeakerWorker?
    private var journal: FileHandle?
    private var generation = UUID()
    private(set) var revision = 0
    var onChange: (() -> Void)?
    private func notify() { revision &+= 1; onChange?() }
    static var rootOverride: URL?
    static var root: URL {
        if let rootOverride { return rootOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingRecorder/Speakers")
    }
    static var models: URL { root.appendingPathComponent("speaker-diarization") }
    private var peopleURL: URL { Self.root.appendingPathComponent("people.json") }

    init() {
        do {
            if FileManager.default.fileExists(atPath: peopleURL.path) {
                people = try JSONDecoder().decode([VoicePerson].self, from: Data(contentsOf: peopleURL))
            }
            refreshModel()
        } catch { libraryReadable = false; status = "人员库读取失败：\(error.localizedDescription)" }
    }
    func refreshModel() {
        ready = ["pyannote_segmentation.mlmodelc", "wespeaker_v2.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: Self.models.appendingPathComponent($0 + "/coremldata.bin").path)
        } && FileManager.default.fileExists(atPath: Self.models.appendingPathComponent("identity.txt").path)
        status = ready ? "模型已安装 · 全程本地识别" : "模型未就绪，请下载或导入完整模型目录。"
    }
    func download() async {
        guard !downloading, worker == nil else { return }
        downloading = true; progress = 0; status = "正在从 Hugging Face 下载模型……"
        defer { downloading = false; notify() }
        #if canImport(FluidAudio)
        do {
            let directory = Self.models
            let callback: ProgressHandler = { [weak self] p in
                Task { @MainActor in self?.progress = p.fractionCompleted }
            }
            let fingerprint = try await Task.detached(priority: .utility) {
                let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndNeuralEngine
                _ = try await DiarizerModels.download(to: directory, configuration: configuration, progressHandler: callback)
                return try SpeakerModelFiles.fingerprint(directory)
            }.value
            try fingerprint.write(to: directory.appendingPathComponent("identity.txt"), atomically: true, encoding: .utf8)
            refreshModel(); progress = 1
        } catch { status = "模型下载失败，可重试：\(error.localizedDescription)" }
        #else
        status = "此构建未包含 FluidAudio，请使用正式构建脚本。"
        #endif
    }
    func showModelDirectory() {
        do {
            try FileManager.default.createDirectory(at: Self.models, withIntermediateDirectories: true)
            guard NSWorkspace.shared.open(Self.models) else { throw problem("Finder 无法打开模型目录。") }
        } catch { status = "打开目录失败：\(error.localizedDescription)" }
    }
    func importModels(from source: URL) async {
        guard !downloading, !importing, worker == nil else { return }
        importing = true; status = "正在复制并验证本地模型……"
        defer { importing = false; notify() }
        let destination = Self.models
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        do {
            try await Task.detached(priority: .utility) {
                try SpeakerModelFiles.install(from: source, to: destination) { directory in
                    #if canImport(FluidAudio)
                    let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine
                    _ = try DiarizerModels.load(
                        localSegmentationModel: directory.appendingPathComponent("pyannote_segmentation.mlmodelc"),
                        localEmbeddingModel: directory.appendingPathComponent("wespeaker_v2.mlmodelc"), configuration: config)
                    #else
                    throw problem("此构建未包含说话人模型运行时")
                    #endif
                }
            }.value
            refreshModel()
            status = "本地模型已导入，可离线识别。模型版本改变时需重新登记声纹。"
        } catch { status = "导入失败，原模型保留：\(error.localizedDescription)" }
    }
    func open(_ directory: URL?) {
        generation = UUID(); matchEvidence = [:]; folder = directory; speakers = []; turns = []; modelID = ""
        guard let directory else { notify(); return }
        do {
            let path = directory.appendingPathComponent("speakers.json")
            if FileManager.default.fileExists(atPath: path.path) {
                let record = try JSONDecoder().decode(SpeakerRecord.self, from: Data(contentsOf: path))
                modelID = record.model; speakers = record.speakers
                // Keep only recent turns for live preview; full timeline remains on disk.
                let data = try String(contentsOf: directory.appendingPathComponent("speaker-turns.jsonl"), encoding: .utf8)
                turns = data.split(separator: "\n").suffix(2000).compactMap { try? JSONDecoder().decode(SpeakerTurn.self, from: Data($0.utf8)) }
            }
        } catch { status = "说话人记录读取失败：\(error.localizedDescription)" }
        notify()
    }
    func start(folder: URL) async throws {
        guard enabled else { open(folder); return }
        refreshModel()
        guard ready else { throw problem("请先在设置中下载说话人模型。") }
        open(folder)
        modelID = try String(contentsOf: Self.models.appendingPathComponent("identity.txt"), encoding: .utf8) + ":clean-speech-v2"
        let token = generation
        let directory = Self.models
        worker = try await Task.detached(priority: .utility) { [weak self] in
            try SpeakerWorker(directory: directory) { [weak self] updates, error in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.receive(updates, error: error)
                }
            }
        }.value
        let path = folder.appendingPathComponent("speaker-turns.jsonl")
        FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
        journal = try FileHandle(forWritingTo: path)
        try persist()
        status = "本地说话人分析 · 约 4 秒更新 · 短句可能待确认"
    }
    var audioReceiver: ((AVAudioPCMBuffer, String, Double) -> Void)? {
        guard let worker else { return nil }
        return { [worker] pcm, track, time in worker.enqueue(pcm, track: track, start: time) }
    }
    func finish() async {
        await worker?.finish(); worker = nil
        // Worker callbacks are delivered on MainActor before this continuation resumes.
        do { try journal?.synchronize(); try journal?.close(); journal = nil; try persist() }
        catch { status = "说话人记录保存失败：\(error.localizedDescription)" }
        notify()
    }
    func receive(_ updates: [SpeakerUpdate], error: String?) {
        if let error { status = error }
        do {
            for update in updates {
                let id = update.turn.speakerID
                let duration = update.turn.end - update.turn.start
                let clean = duration >= 1.5 && !updates.contains { other in
                    other.turn.track == update.turn.track && other.turn.speakerID != id &&
                    min(other.turn.end, update.turn.end) - max(other.turn.start, update.turn.start) > 0.1
                }
                if let index = speakers.firstIndex(where: { $0.id == id }) {
                    if clean {
                        speakers[index].speechSeconds += duration
                        if duration >= (speakers[index].sampleSeconds ?? 0), let normalized = VoiceIdentity.normalized(update.embedding) {
                            speakers[index].embedding = normalized; speakers[index].sampleSeconds = duration
                        }
                    }
                } else if speakers.count < 128 {
                    speakers.append(MeetingSpeaker(id: id, track: update.turn.track,
                        number: speakers.filter { $0.track == update.turn.track }.count + 1,
                        embedding: clean ? (VoiceIdentity.normalized(update.embedding) ?? []) : [], speechSeconds: clean ? duration : 0,
                        sampleSeconds: clean ? duration : 0))
                }
                turns.append(update.turn)
                var data = try JSONEncoder().encode(update.turn); data.append(10)
                try journal?.write(contentsOf: data)
            }
            // One vote per callback and speaker: segmentation can emit several
            // ranges carrying the same embedding, including buffered early turns.
            for id in Set(updates.map { $0.turn.speakerID }) {
                guard let index = speakers.firstIndex(where: { $0.id == id }), !speakers[index].confirmed else { continue }
                let clean = updates.filter { update in
                    update.turn.speakerID == id && update.turn.end - update.turn.start >= 1.5 &&
                    !updates.contains { other in
                        other.turn.track == update.turn.track && other.turn.speakerID != id &&
                        min(other.turn.end, update.turn.end) - max(other.turn.start, update.turn.start) > 0.1
                    }
                }
                guard let sample = clean.max(by: { $0.turn.start < $1.turn.start }) else { continue }
                var evidence = matchEvidence[id] ?? SpeakerMatchEvidence()
                let match = evidence.observe(sample.embedding, seconds: sample.turn.end - sample.turn.start,
                                             people: people, model: modelID)
                matchEvidence[id] = evidence
                speakers[index].personID = match?.id; speakers[index].name = match?.name
            }
            turns = Array(turns.suffix(2000))
            if !updates.isEmpty { try persist() }
        } catch { status = "说话人记录保存失败：\(error.localizedDescription)" }
        notify()
    }
    func captionLines(_ cue: CaptionCue) -> [String] {
        cue.splitBySpeaker(turns: turns).map {
            label(track: $0.track, start: $0.start, end: $0.end) + "：" + $0.text
        }
    }

    func label(track: String, start: Double, end: Double) -> String {
        VoiceIdentity.label(track: track, start: start, end: end, turns: turns, speakers: speakers)
    }
    private func persist() throws {
        guard let folder, !modelID.isEmpty else { return }
        try VoiceIdentity.write(SpeakerRecord(model: modelID, speakers: speakers), to: folder.appendingPathComponent("speakers.json"))
    }
    func annotate(id: String, name: String, remember: Bool, personID: String? = nil) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        let name = name.split(whereSeparator: { $0.isNewline }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { status = "请输入 1–80 字的姓名。"; return }
        let oldSpeakers = speakers, oldPeople = people
        do {
            var identity: String? = personID
            if remember {
                guard libraryReadable else { throw problem("人员库读取异常，已保留原文件；请先修复人员库再登记。") }
                guard speakers[index].speechSeconds >= 3, !speakers[index].embedding.isEmpty else {
                    status = "清晰语音不足 3 秒，请等此人继续发言后再记住声纹。"; return
                }
                let existingID = personID ?? (speakers[index].name == name ? speakers[index].personID : nil)
                if let existingID, let p = people.firstIndex(where: { $0.id == existingID && $0.model == modelID }) {
                    identity = existingID
                    people[p].samples = Array((people[p].samples + [speakers[index].embedding]).suffix(5))
                } else {
                    identity = UUID().uuidString
                    people.append(VoicePerson(id: identity!, name: name, model: modelID, samples: [speakers[index].embedding]))
                }
                try VoiceIdentity.write(people, to: peopleURL)
            }
            speakers[index].name = name; speakers[index].personID = identity; speakers[index].confirmed = true
            try persist()
            status = remember ? "已记住声纹，后续录音自动匹配；已导出的字幕请重新保存。" : "本场姓名已更新；已导出的字幕请重新保存。"
        } catch { speakers = oldSpeakers; people = oldPeople; status = "标注保存失败：\(error.localizedDescription)" }
        notify()
    }
    func forget(_ id: String) {
        do {
            guard libraryReadable else { throw problem("人员库读取异常，不能覆盖原文件。") }
            let remaining = people.filter { $0.id != id }
            try VoiceIdentity.write(remaining, to: peopleURL); people = remaining
            status = "已删除此人的持久声纹；历史录音中的姓名保留。"
        } catch { status = "删除失败：\(error.localizedDescription)" }
        notify()
    }
}

struct SpeakerUpdate {
    var turn: SpeakerTurn
    var embedding: [Float]
}

// All model inference and resampling use one utility queue. Bounded ingress prevents
// slow hardware from accumulating an entire meeting in memory or blocking capture.
final class SpeakerWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "meeting.speakers", qos: .utility)
    private let slots = DispatchSemaphore(value: 256)
    private var queuedSeconds = 0.0
    private let lock = NSLock()
    private var accepting = true
    private var dropped = false
    private let callback: ([SpeakerUpdate], String?) -> Void
    private var buffers: [String: [Float]] = [:]
    private var starts: [String: Double] = [:]
    private var converters: [String: AVAudioConverter] = [:]
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    #if canImport(FluidAudio)
    private var analyzer: CleanSpeakerAnalyzer?
    #endif
    init(directory: URL, callback: @escaping ([SpeakerUpdate], String?) -> Void) throws {
        self.callback = callback
        #if canImport(FluidAudio)
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine
        let models = try DiarizerModels.load(localSegmentationModel: directory.appendingPathComponent("pyannote_segmentation.mlmodelc"),
                                             localEmbeddingModel: directory.appendingPathComponent("wespeaker_v2.mlmodelc"), configuration: config)
        analyzer = CleanSpeakerAnalyzer(models: models)
        #else
        throw problem("此构建未包含说话人模型运行时")
        #endif
    }
    func enqueue(_ pcm: AVAudioPCMBuffer, track: String, start: Double) {
        lock.lock(); defer { lock.unlock() }
        guard accepting, pcm.format.sampleRate > 0 else { return }
        let duration = Double(pcm.frameLength) / pcm.format.sampleRate
        guard duration <= 2, queuedSeconds + duration <= 8,
              slots.wait(timeout: .now()) == .success else { dropped = true; return }
        queuedSeconds += duration
        let reportDrop = dropped; dropped = false
        queue.async { [self] in
            defer {
                lock.lock(); queuedSeconds -= duration; lock.unlock()
                slots.signal()
            }
            if reportDrop { callback([], "设备繁忙，已跳过部分说话人分析；录音和文字继续保存。") }
            do { try consume(pcm, track: track, start: start) }
            catch { callback([], "说话人分析异常：\(error.localizedDescription)") }
        }
    }
    private func consume(_ pcm: AVAudioPCMBuffer, track: String, start: Double) throws {
        guard pcm.frameLength > 0, pcm.frameLength <= AVAudioFrameCount(pcm.format.sampleRate * 2), start.isFinite else { return }
        let expected = (starts[track] ?? start) + Double(buffers[track]?.count ?? 0) / 16000
        if abs(expected - start) > 0.08 || converters[track]?.inputFormat != pcm.format {
            try flush(track); converters[track] = AVAudioConverter(from: pcm.format, to: format); starts[track] = start
        }
        guard let converter = converters[track] else { return }
        let capacity = AVAudioFrameCount(ceil(Double(pcm.frameLength) * 16000 / pcm.format.sampleRate)) + 64
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var supplied = false; var error: NSError?
        converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return pcm
        }
        if let error { throw error }
        guard let channel = output.floatChannelData?[0] else { return }
        if starts[track] == nil { starts[track] = start }
        buffers[track, default: []].append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        while (buffers[track]?.count ?? 0) >= 64000 {
            let chunk = Array(buffers[track]!.prefix(64000))
            let time = starts[track]!
            buffers[track]!.removeFirst(64000); starts[track] = time + 4
            try analyze(chunk, track: track, start: time)
        }
    }
    private func flush(_ track: String) throws {
        let chunk = buffers.removeValue(forKey: track) ?? []
        let time = starts.removeValue(forKey: track) ?? 0
        if chunk.count >= 8000 { try analyze(chunk, track: track, start: time) }
    }
    private func analyze(_ samples: [Float], track: String, start: Double) throws {
        guard samples.reduce(Float(0), { $0 + $1 * $1 }) / Float(samples.count) > 0.000001 else { return }
        #if canImport(FluidAudio)
        guard let analyzer else { return }
        callback(try analyzer.analyze(samples, track: track, start: start), nil)
        #endif
    }
    func finish() async {
        await withCheckedContinuation { continuation in
            lock.lock(); accepting = false
            queue.async { [self] in
                do { for track in ["microphone", "system"] { try flush(track) } }
                catch { callback([], "说话人尾段处理失败：\(error.localizedDescription)") }
                // Dispatch in order after callbacks queued by the utility worker.
                DispatchQueue.main.async { continuation.resume() }
            }
            lock.unlock()
        }
    }
}

// Stage and validate before replacing the active directory. Never copy people.json
// or trust an imported identity.txt; derive identity from actual copied assets.
enum SpeakerModelFiles {
    static let bundles = ["pyannote_segmentation.mlmodelc", "wespeaker_v2.mlmodelc"]
    static func sourceDirectory(_ selection: URL) throws -> URL {
        let candidates = [selection, selection.appendingPathComponent("speaker-diarization"),
                          selection.appendingPathComponent("speaker-diarization-coreml")]
        guard let source = candidates.first(where: { directory in
            bundles.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0 + "/coremldata.bin").path) }
        }) else { throw problem("请选择包含 pyannote_segmentation.mlmodelc 和 wespeaker_v2.mlmodelc 的文件夹，两个模型目录都必须完整。压缩包请先解压。") }
        return source
    }
    static func fingerprint(_ directory: URL) throws -> String {
        // FileManager canonicalizes /var to /private/var; hash only stable relative paths.
        let directory = directory.resolvingSymlinksInPath()
        var hash = SHA256()
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw problem("无法读取模型目录。")
        }
        let files = enumerator.compactMap { ($0 as? URL)?.resolvingSymlinksInPath() }.filter { file in
            bundles.contains { file.path.hasPrefix(directory.appendingPathComponent($0).path + "/") } &&
                (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw problem("模型目录为空。") }
        for file in files {
            hash.update(data: Data(file.path.replacingOccurrences(of: directory.path, with: "").utf8))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func install(from selection: URL, to destination: URL, validate: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let source = try sourceDirectory(selection)
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".model-import-" + UUID().uuidString)
        let backup = parent.appendingPathComponent(".model-backup-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        for name in bundles { try fm.copyItem(at: source.appendingPathComponent(name), to: stage.appendingPathComponent(name)) }
        // Keep copied assets self-contained; reject symlinks before loading them.
        if let items = fm.enumerator(at: stage, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in items {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    throw problem("模型目录包含符号链接，请导入完整的实际模型文件。")
                }
            }
        }
        try validate(stage)
        let contentID = try fingerprint(stage)
        // v0.9.0 hashed repository metadata as well. Preserve its identity when the
        // actual model bundles match, so reimporting does not invalidate enrollment.
        let oldIdentity = try? String(contentsOf: destination.appendingPathComponent("identity.txt"), encoding: .utf8)
        let sameAssets = (try? fingerprint(destination)) == contentID
        let validOldID = oldIdentity.map { $0.count == 64 && $0.allSatisfy { $0.isHexDigit } } ?? false
        let identity = sameAssets && validOldID ? oldIdentity! : contentID
        try identity.write(to: stage.appendingPathComponent("identity.txt"), atomically: true, encoding: .utf8)
        let hadModel = fm.fileExists(atPath: destination.path)
        if hadModel { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: stage, to: destination) }
        catch {
            if hadModel { try fm.moveItem(at: backup, to: destination) }
            throw error
        }
        if hadModel { try? fm.removeItem(at: backup) }
    }
}

#if canImport(FluidAudio)
// The segmentation model uses 10 s, but WeSpeaker must not embed a 4 s signal
// padded with 6 s of zeros: its whole-window log-mel mean collapses identity.
// Segment first, collect only non-overlapping speech, then repeat that speech to
// fill WeSpeaker's fixed window (the same principle as FluidAudio embedSpan).
final class CleanSpeakerAnalyzer {
    private let models: DiarizerModels
    private let segmentation = SegmentationProcessor()
    private let extractor: EmbeddingExtractor
    private var clusters: [String: LiveSpeakerClusters] = [:]
    private var pending: [String: [SpeakerUpdate]] = [:]
    private var levels: [String: (time: Double, rms: Float)] = [:]
    init(models: DiarizerModels) {
        self.models = models
        extractor = EmbeddingExtractor(embeddingModel: models.embeddingModel)
    }
    func analyze(_ samples: [Float], track: String, start: Double) throws -> [SpeakerUpdate] {
        guard !samples.isEmpty, samples.count <= 160_000 else { return [] }
        let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
        levels[track] = (start, rms)
        let other = levels[track == "system" ? "microphone" : "system"]
        // Weak return audio must not become a third participant while the other
        // source is speaking loudly. This affects labels only, never saved audio.
        let weakReturn = other.map { abs($0.time - start) <= 4.1 && rms < 0.02 && $0.rms > rms * 4 } ?? false
        guard !weakReturn else { return [] }
        let (segmented, _) = try segmentation.getSegments(audioChunk: samples[...], segmentationModel: models.segmentationModel)
        guard let frames = segmented.first, let first = frames.first else { return [] }
        var output: [SpeakerUpdate] = []
        for speaker in first.indices {
            let ranges = Self.cleanRanges(frames: frames, speaker: speaker, sampleCount: samples.count)
            let speech = ranges.flatMap { Array(samples[$0]) }
            guard speech.count >= 16_000 else { continue }
            // All-one weights: every sample now belongs to this local speaker.
            let embedding = try extractor.getEmbeddings(audio: speech,
                masks: [[Float](repeating: 1, count: frames.count)])[0]
            var tracker = clusters[track] ?? LiveSpeakerClusters()
            let match = tracker.observe(embedding, seconds: Double(speech.count) / 16_000, at: start)
            clusters[track] = tracker
            guard let match else { continue }
            let id = track + ":" + String(match.id)
            if match.reset { pending[id] = nil }
            let updates = ranges.filter { $0.count >= 11_200 }.map { range in
                SpeakerUpdate(turn: SpeakerTurn(track: track, speakerID: id,
                    start: start + Double(range.lowerBound) / 16_000,
                    end: start + Double(range.upperBound) / 16_000), embedding: embedding)
            }
            if match.confirmed {
                output += pending.removeValue(forKey: id) ?? []
                output += updates
            } else {
                pending[id] = Array(((pending[id] ?? []) + updates).suffix(12))
            }
        }
        return output.sorted { $0.turn.start < $1.turn.start }
    }
    // Pyannote frame step is 270 samples at 16 kHz; clip to REAL input duration.
    static func cleanRanges(frames: [[Float]], speaker: Int, sampleCount: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []; var begin: Int?
        for frame in 0...frames.count {
            let active = frame < frames.count && frame * 270 < sampleCount &&
                speaker < frames[frame].count && frames[frame][speaker] > 0.5 && frames[frame].reduce(0, +) < 2
            if active && begin == nil { begin = frame * 270 }
            if !active, let lower = begin {
                ranges.append(lower..<min(frame * 270, sampleCount)); begin = nil
            }
        }
        return ranges
    }
}
#endif
