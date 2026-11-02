import AVFoundation
import Darwin
import Foundation

// Queue-confined PCM processing. This class never opens an audio device.
final class SoftwareEchoCanceller {
    private typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias Reset = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias Process = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<Float>, UnsafePointer<Float>, UnsafeMutablePointer<Float>) -> Int32
    private let library: UnsafeMutableRawPointer
    private let state: UnsafeMutableRawPointer
    private let destroy: Destroy
    private let resetNative: Reset
    private let process: Process
    private let epoch: Double
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    private var converters: [String: AVAudioConverter] = [:]
    private struct Frame {
        var samples = [Float](repeating: 0, count: 480)
        var first = 480
        var end = 0
    }
    private var microphone: [Int: Frame] = [:]
    private var reference: [Int: Frame] = [:]
    // Measured group delay for the pinned 2.1 AEC3 + 48 kHz filterbank.
    // The numerical speech-preservation test verifies this compensation.
    private let latencySamples = 430
    private var pending: (index: Int, near: Frame?, farPresent: Bool, output: [Float])?
    private var nextFrame: Int?
    private var latestFrame = -1
    private var closedThrough = -1
    private(set) var missingReferenceFrames = 0
    // Both callback streams may arrive out of order. Hold 150 ms on the host
    // timeline before consuming, independently of packet size and callback order.
    private let holdbackFrames = 15

    init(epoch: Double) throws {
        self.epoch = epoch
        let directory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libMeetingAEC.dylib")
        let path = FileManager.default.fileExists(atPath: bundled.path) ? bundled.path : directory.appendingPathComponent("libMeetingAEC.dylib").path
        guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw problem("软件回声消除组件无法加载，请重新构建或安装应用。")
        }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(library, name) else { throw problem("软件回声消除组件版本不匹配。") }
            return unsafeBitCast(address, to: T.self)
        }
        do {
            let create = try symbol("meeting_aec_create", Create.self)
            destroy = try symbol("meeting_aec_destroy", Destroy.self)
            resetNative = try symbol("meeting_aec_reset", Reset.self)
            process = try symbol("meeting_aec_process", Process.self)
            guard let state = create() else { throw problem("无法初始化软件回声消除。") }
            self.state = state
            self.library = library
        } catch { dlclose(library); throw error }
    }

    deinit { destroy(state); dlclose(library) }

    func reset() throws {
        microphone.removeAll(); reference.removeAll(); converters.removeAll()
        pending = nil
        nextFrame = nil; latestFrame = -1; closedThrough = -1
        guard resetNative(state) == 0 else { throw problem("无法重置软件回声消除。") }
    }

    private func mono(_ pcm: AVAudioPCMBuffer, track: String) throws -> [Float] {
        guard pcm.frameLength > 0, pcm.format.sampleRate > 0,
              Double(pcm.frameLength) / pcm.format.sampleRate <= 1 else { throw problem("软件回声消除收到异常音频长度。") }
        if pcm.format == format, let data = pcm.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: data, count: Int(pcm.frameLength)))
        }
        let converter: AVAudioConverter
        if let existing = converters[track], existing.inputFormat == pcm.format { converter = existing }
        else {
            guard let created = AVAudioConverter(from: pcm.format, to: format) else { throw problem("无法转换回声消除音频格式。") }
            created.primeMethod = .none
            converter = created; converters[track] = created
        }
        let capacity = AVAudioFrameCount(ceil(Double(pcm.frameLength) * 48000 / pcm.format.sampleRate) + 512)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, result in
            if supplied { result.pointee = .noDataNow; return nil }
            supplied = true; result.pointee = .haveData; return pcm
        }
        guard status != .error, error == nil, let data = output.floatChannelData?[0] else {
            throw problem("回声消除音频转换失败：\(error?.localizedDescription ?? "未知错误")")
        }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }

    func ingest(_ pcm: AVAudioPCMBuffer, track: String, timestamp: Double,
                deliver: (AVAudioPCMBuffer, Double) -> Void) throws {
        let relative = timestamp - epoch
        guard relative.isFinite, relative >= -1, relative < 60 * 60 * 24 else { throw problem("软件回声消除音频时间戳异常。") }
        let samples = try mono(pcm, track: track)
        let start = Int((relative * 48000).rounded())
        var frames = track == "microphone" ? microphone : reference
        var offset = max(0, -start)
        while offset < samples.count {
            let position = start + offset
            let index = position / 480
            let within = position % 480
            let count = min(480 - within, samples.count - offset)
            if index > closedThrough {
                var frame = frames.removeValue(forKey: index) ?? Frame()
                frame.samples.replaceSubrange(within..<(within + count), with: samples[offset..<(offset + count)])
                frame.first = min(frame.first, within); frame.end = max(frame.end, within + count)
                frames[index] = frame
                nextFrame = min(nextFrame ?? index, index)
                latestFrame = max(latestFrame, index)
            }
            offset += count
        }
        if track == "microphone" { microphone = frames } else { reference = frames }
        guard microphone.count + reference.count <= 240 else { throw problem("软件回声消除缓冲区溢出，已停止录音。") }
        try drain(through: latestFrame - holdbackFrames, deliver: deliver)
    }

    func finish(deliver: (AVAudioPCMBuffer, Double) -> Void) throws {
        try drain(through: latestFrame, deliver: deliver)
        if let pending {
            // One silent lookahead frame drains AEC3/filterbank latency, including
            // the final partial input frame. Never save the lookahead as new audio.
            var output = [Float](repeating: 0, count: 480)
            let silence = [Float](repeating: 0, count: 480)
            guard process(state, silence, silence, &output) == 0 else { throw problem("软件回声消除收尾失败。") }
            emit(pending, following: output, deliver: deliver)
            self.pending = nil
        }
    }

    private func drain(through limit: Int, deliver: (AVAudioPCMBuffer, Double) -> Void) throws {
        guard var index = nextFrame, index <= limit else { return }
        // Large discontinuities (sleep/device stalls) reset adaptation without
        // allocating or processing an unbounded span of silent audio.
        if limit - index > 200 {
            if let pending { emit(pending, following: pending.output, bypass: true, deliver: deliver); self.pending = nil }
            guard resetNative(state) == 0 else { throw problem("无法重置软件回声消除。") }
            index = min(microphone.keys.min() ?? limit, reference.keys.min() ?? limit)
        }
        while index <= limit {
            if microphone[index] == nil, reference[index] == nil,
               let upcoming = (Array(microphone.keys) + Array(reference.keys)).filter({ $0 > index }).min(), upcoming - index > 100 {
                if let pending { emit(pending, following: pending.output, bypass: true, deliver: deliver); self.pending = nil }
                guard resetNative(state) == 0 else { throw problem("无法重置软件回声消除。") }
                index = min(upcoming, limit + 1)
                continue
            }
            let near = microphone.removeValue(forKey: index)
            let far = reference.removeValue(forKey: index)
            let capture = near?.samples ?? [Float](repeating: 0, count: 480)
            let render = far?.samples ?? [Float](repeating: 0, count: 480)
            var output = [Float](repeating: 0, count: 480)
            let status = process(state, render, capture, &output)
            guard status == 0 else { throw problem("软件回声消除处理失败：\(status)") }
            if let pending { emit(pending, following: output, deliver: deliver) }
            pending = (index, near, far != nil, output)
            closedThrough = index
            index += 1
        }
        nextFrame = index
    }

    private func emit(_ frame: (index: Int, near: Frame?, farPresent: Bool, output: [Float]),
                      following: [Float], bypass: Bool = false,
                      deliver: (AVAudioPCMBuffer, Double) -> Void) {
        guard let near = frame.near else { return }
        if !frame.farPresent { missingReferenceFrames += 1 }
        let source = !frame.farPresent || bypass ? near.samples
            : Array(frame.output[latencySamples..<480]) + Array(following[0..<latencySamples])
        let count = near.end - near.first
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        source.withUnsafeBufferPointer { data in
            buffer.floatChannelData![0].update(from: data.baseAddress! + near.first, count: count)
        }
        deliver(buffer, epoch + Double(frame.index * 480 + near.first) / 48000)
    }

}
