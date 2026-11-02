import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI
import Darwin

struct Fragment: Codable {
    var file: String
    var track: String
    var start: Double
    var duration: Double
}

struct Manifest: Codable {
    var version = 1
    var created = ISO8601DateFormatter().string(from: Date())
    var state = "recording"
    var duration = 0.0
    var error: String? = nil
    var fragments: [Fragment] = []
    var microphoneProcessing: String? = nil
    var echoReferenceMissingFrames: Int? = nil
}

func problem(_ message: String) -> NSError {
    NSError(domain: "MeetingRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

// Mutable capture and software AEC state are confined to queue.
final class AudioSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.meeting.audio")
    let folder: URL
    let epoch: Double
    private let clock: () -> Double
    private var pauseStarted: Double?
    private var pausedSeconds = 0.0
    private var resumedAt: Double?
    private var endedAt: Double?
    var elapsed: Double { max(0, (endedAt ?? pauseStarted ?? clock()) - epoch - pausedSeconds) }
    private var echoCanceller: SoftwareEchoCanceller?
    var manifest = Manifest()
    var files: [String: AVAudioFile] = [:]
    var indices: [String: Int] = [:]
    var paused = false
    var finished = false
    var lastCheckpoint = 0.0
    var levels: (Float, Float) = (0, 0)
    var onFailure: ((String) -> Void)?
    var onAudio: ((AVAudioPCMBuffer, String, Double) -> Void)?
    private var pausedTracks: Set<String> = []
    private var trackResumedAt: [String: Double] = [:]
    private var lockFD: Int32 = -1
    private var processingEcho = false
    private var echoDeliveryError: Error?

    private func processEcho(_ body: () throws -> Void) throws {
        processingEcho = true
        echoDeliveryError = nil
        defer { processingEcho = false; echoDeliveryError = nil }
        try body()
        if let error = echoDeliveryError { throw error }
    }

    private func flushEcho() throws {
        try processEcho {
            try echoCanceller?.finish { self.receivePCM($0, track: "microphone", timestamp: $1) }
        }
    }

    init(folder: URL, softwareEchoCancellation: Bool = false, clock: @escaping () -> Double = { CMClockGetTime(CMClockGetHostTimeClock()).seconds }) throws {
        self.folder = folder
        self.clock = clock
        self.epoch = clock()
        super.init()
        if softwareEchoCancellation {
            echoCanceller = try SoftwareEchoCanceller(epoch: epoch)
            manifest.microphoneProcessing = "webrtcAEC3"
        }
        lockFD = Darwin.open(folder.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw problem("无法锁定录音目录") }
        try checkpoint()
    }

    deinit { if lockFD >= 0 { Darwin.close(lockFD) } }

    func checkpoint() throws {
        if let echoCanceller { manifest.echoReferenceMissingFrames = echoCanceller.missingReferenceFrames }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
    }

    func closeFiles() { files.removeAll(); indices.removeAll(); levels = (0, 0) }

    func setTrackPaused(_ track: String, _ value: Bool) throws {
        guard !finished, ["microphone", "system"].contains(track) else { return }
        if value, track == "microphone", !pausedTracks.contains(track) {
            try flushEcho()
            try echoCanceller?.reset()
        }
        if value { pausedTracks.insert(track) }
        else { pausedTracks.remove(track); trackResumedAt[track] = clock() }
        files[track] = nil
        indices[track] = nil
        if track == "microphone" { levels.0 = 0 } else { levels.1 = 0 }
        manifest.duration = max(manifest.duration, elapsed)
        try checkpoint()
    }

    func setPaused(_ value: Bool) throws {
        guard !finished, value != paused else { return }
        let now = clock()
        if value {
            try flushEcho()
            try echoCanceller?.reset()
            pauseStarted = now
        } else if let started = pauseStarted {
            pausedSeconds += max(0, now - started)
            pauseStarted = nil
            resumedAt = now
        }
        paused = value
        closeFiles()
        manifest.duration = max(manifest.duration, elapsed)
        manifest.state = value ? "paused" : "recording"
        try checkpoint()
    }

    func finish(error: String? = nil) throws {
        guard !finished else { return }
        var failure = error
        var processingFailure: Error?
        do { try flushEcho() } catch {
            processingFailure = error
            failure = failure ?? error.localizedDescription
        }
        guard !finished else { return }
        endedAt = pauseStarted ?? clock()
        finished = true
        closeFiles()
        manifest.duration = max(manifest.duration, elapsed)
        manifest.state = failure == nil ? "completed" : "interrupted"
        manifest.error = failure
        defer {
            if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1 }
        }
        try checkpoint()
        if let processingFailure { throw processingFailure }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.fail(error) }
    }

    func fail(_ error: Error) {
        guard !finished else { return }
        try? finish(error: error.localizedDescription)
        onFailure?(error.localizedDescription)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        receive(sample, type: type)
    }

    func receive(_ sample: CMSampleBuffer, type: SCStreamOutputType) {
        guard !paused, !finished, sample.isValid, CMSampleBufferDataIsReady(sample),
              type == .audio || type == .microphone else { return }
        do {
            let track = type == .microphone ? "microphone" : "system"
            if echoCanceller == nil {
                guard !pausedTracks.contains(track) else { return }
                if let resumed = trackResumedAt[track], sample.presentationTimeStamp.seconds < resumed { return }
            }
            if let resumedAt, sample.presentationTimeStamp.seconds < resumedAt { return }
            guard let description = sample.formatDescription,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let format = AVAudioFormat(streamDescription: asbd) else {
                throw problem("无法读取音频格式")
            }
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
            pcm.frameLength = AVAudioFrameCount(count)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList)
            guard status == noErr else { throw problem("音频缓冲区读取失败：\(status)") }
            let timestamp = sample.presentationTimeStamp.seconds
            if let echoCanceller {
                try processEcho {
                    try echoCanceller.ingest(pcm, track: track, timestamp: timestamp) {
                        self.receivePCM($0, track: "microphone", timestamp: $1)
                    }
                }
                if track == "system" { receivePCM(pcm, track: track, timestamp: timestamp) }
            } else {
                receivePCM(pcm, track: track, timestamp: timestamp)
            }
        } catch { fail(error) }
    }

    // Both sources use host-clock seconds and the same pause-compacted timeline.
    // Called exclusively on queue; also used by the processed microphone delivery.
    func receivePCM(_ pcm: AVAudioPCMBuffer, track: String, timestamp: Double) {
        guard !paused, !finished, ["microphone", "system"].contains(track), !pausedTracks.contains(track) else { return }
        if let resumed = trackResumedAt[track], timestamp < resumed { return }
        do {
            let format = pcm.format
            let count = Int(pcm.frameLength)
            guard count > 0 else { return }
            // A queued callback may arrive after resume but belong to the pause.
            if let resumedAt, timestamp < resumedAt { return }
            let start = timestamp - epoch - pausedSeconds
            guard start.isFinite, start >= -1 else { throw problem("音频时间戳异常，已停止录音以保留文件") }
            let duration = Double(count) / format.sampleRate
            if let index = indices[track], let file = files[track] {
                let previous = manifest.fragments[index]
                if previous.duration >= 30 || abs(start - previous.start - previous.duration) > 0.05 || file.processingFormat != format {
                    files[track] = nil
                    indices[track] = nil
                }
            }
            if files[track] == nil {
                let free = try FileManager.default.attributesOfFileSystem(forPath: folder.path)[.systemFreeSize] as? NSNumber
                guard (free?.int64Value ?? 0) > 512 * 1024 * 1024 else { throw problem("磁盘剩余空间不足 512 MB，录音已停止") }
                let name = String(format: "%@-%06d.caf", track, manifest.fragments.count)
                var settings = format.settings
                settings[AVLinearPCMIsNonInterleaved] = false
                let file = try AVAudioFile(forWriting: folder.appendingPathComponent(name), settings: settings,
                                           commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                files[track] = file
                indices[track] = manifest.fragments.count
                manifest.fragments.append(Fragment(file: name, track: track, start: max(0, start), duration: 0))
                try checkpoint()
            }
            try files[track]!.write(from: pcm)
            onAudio?(pcm, track, max(0, start))
            let index = indices[track]!
            manifest.fragments[index].duration += duration
            manifest.duration = max(manifest.duration, start + duration)
            var peak: Float = 0
            if let channels = pcm.floatChannelData {
                for channel in 0..<(format.isInterleaved ? 1 : Int(format.channelCount)) {
                    let samples = count * (format.isInterleaved ? Int(format.channelCount) : 1)
                    for i in 0..<samples { peak = max(peak, abs(channels[channel][i])) }
                }
            }
            let level = min(1, max(0, (20 * log10(max(peak, 0.0001)) + 60) / 60))
            if track == "microphone" { levels.0 = level } else { levels.1 = level }
            if start - lastCheckpoint >= 1 {
                try checkpoint()
                lastCheckpoint = start
            }
        } catch {
            if processingEcho { echoDeliveryError = echoDeliveryError ?? error }
            else { fail(error) }
        }
    }
}
