import AVFoundation
import ScreenCaptureKit

@main struct AudioSinkSmoke {
    static func sample(rate: Double, channels: AVAudioChannelCount, start: Double) throws -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let frames = AVAudioFrameCount(rate / 10)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        pcm.frameLength = frames
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) { pcm.floatChannelData![channel][i] = 0.25 }
        }
        var description: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        precondition(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: Int(frames),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &result) == noErr)
        precondition(CMSampleBufferSetDataBufferFromAudioBufferList(result!, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
        precondition(CMSampleBufferSetDataReady(result!) == noErr)
        return result!
    }

    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-sink-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var now = 100.0
        let sink = try AudioSink(folder: folder, clock: { now })
        var failure: String?
        sink.onFailure = { failure = $0 }
        var captionInputs: [(String, Double)] = []
        sink.onAudio = { _, track, start in captionInputs.append((track, start)) }
        sink.receive(try sample(rate: 48000, channels: 2, start: sink.epoch + 0.2), type: .audio)
        sink.receive(try sample(rate: 44100, channels: 1, start: sink.epoch + 0.4), type: .microphone)
        precondition(failure == nil, failure ?? "")
        precondition(sink.manifest.fragments.count == 2)
        precondition(sink.levels.0 > 0 && sink.levels.1 > 0)
        now = sink.epoch + 0.5
        try sink.setPaused(true)
        now = sink.epoch + 10.5
        precondition(abs(sink.elapsed - 0.5) < 0.0001)
        sink.receive(try sample(rate: 48000, channels: 2, start: sink.epoch + 1), type: .audio)
        precondition(sink.manifest.fragments.count == 2)
        try sink.setPaused(false)
        // Delayed samples from the paused interval must remain discarded.
        sink.receive(try sample(rate: 48000, channels: 2, start: sink.epoch + 9), type: .audio)
        precondition(sink.manifest.fragments.count == 2)
        sink.receive(try sample(rate: 48000, channels: 2, start: sink.epoch + 10.5), type: .audio)
        precondition(abs(sink.manifest.fragments[2].start - 0.5) < 0.0001)
        now = sink.epoch + 10.6
        try sink.setPaused(true)
        now = sink.epoch + 30.6
        precondition(abs(sink.elapsed - 0.6) < 0.0001)
        try sink.setPaused(false)
        sink.receive(try sample(rate: 44100, channels: 1, start: sink.epoch + 30.6), type: .microphone)
        precondition(abs(sink.manifest.fragments[3].start - 0.6) < 0.0001)
        now = sink.epoch + 30.7
        try sink.setPaused(true)
        now = sink.epoch + 90

        try sink.finish()
        precondition(failure == nil, failure ?? "")
        precondition(sink.manifest.state == "completed")
        precondition(sink.manifest.fragments.count == 4)
        precondition(abs(sink.elapsed - 0.7) < 0.0001)
        precondition(abs(sink.manifest.duration - 0.7) < 0.0001)
        precondition(captionInputs.map { $0.0 } == ["system", "microphone", "system", "microphone"])
        for (input, expected) in zip(captionInputs, [0.2, 0.4, 0.5, 0.6]) {
            precondition(abs(input.1 - expected) < 0.0001, "Caption clock must match compacted audio")
        }
        for fragment in sink.manifest.fragments {
            let audio = try AVAudioFile(forReading: folder.appendingPathComponent(fragment.file))
            precondition(abs(Double(audio.length) / audio.processingFormat.sampleRate - 0.1) < 0.001)
        }
        let channelsFolder = folder.appendingPathComponent("channels")
        try FileManager.default.createDirectory(at: channelsFolder, withIntermediateDirectories: false)
        now = 200
        let channels = try AudioSink(folder: channelsFolder, clock: { now })
        captionInputs = []
        channels.onAudio = { _, track, start in captionInputs.append((track, start)) }
        channels.receive(try sample(rate: 48000, channels: 2, start: 200), type: .audio)
        channels.receive(try sample(rate: 44100, channels: 1, start: 200), type: .microphone)
        now = 200.1
        try channels.setTrackPaused("microphone", true)
        channels.receive(try sample(rate: 44100, channels: 1, start: 200.1), type: .microphone)
        channels.receive(try sample(rate: 48000, channels: 2, start: 200.1), type: .audio)
        precondition(channels.manifest.fragments.count == 2)
        precondition(abs(channels.manifest.fragments[0].duration - 0.2) < 0.0001)
        precondition(abs(channels.manifest.fragments[1].duration - 0.1) < 0.0001)
        now = 200.3
        try channels.setTrackPaused("microphone", false)
        channels.receive(try sample(rate: 44100, channels: 1, start: 200.2), type: .microphone)
        precondition(channels.manifest.fragments.count == 2)
        channels.receive(try sample(rate: 44100, channels: 1, start: 200.3), type: .microphone)
        precondition(abs(channels.manifest.fragments[2].start - 0.3) < 0.0001)
        try channels.setTrackPaused("system", true)
        channels.receive(try sample(rate: 48000, channels: 2, start: 200.3), type: .audio)
        precondition(channels.manifest.fragments.count == 3)
        try channels.setTrackPaused("microphone", true)
        now = 200.5
        precondition(abs(channels.elapsed - 0.5) < 0.0001)
        try channels.setPaused(true)
        now = 210.5
        try channels.setPaused(false)
        // Global resume must not re-enable individually paused channels.
        channels.receive(try sample(rate: 44100, channels: 1, start: 210.5), type: .microphone)
        channels.receive(try sample(rate: 48000, channels: 2, start: 210.5), type: .audio)
        precondition(channels.manifest.fragments.count == 3)
        try channels.setTrackPaused("system", false)
        channels.receive(try sample(rate: 48000, channels: 2, start: 210.5), type: .audio)
        precondition(abs(channels.manifest.fragments[3].start - 0.5) < 0.0001)
        now = 210.6
        try channels.finish(error: "Synthetic capture shutdown error")
        precondition(captionInputs.map { $0.0 } == ["system", "microphone", "system", "microphone", "system"])
        for (input, expected) in zip(captionInputs, [0.0, 0.0, 0.1, 0.3, 0.5]) {
            precondition(abs(input.1 - expected) < 0.0001)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/export.py")
        process.arguments = [script.path, channelsFolder.path]
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        precondition(FileManager.default.fileExists(atPath: channelsFolder.appendingPathComponent("meeting.m4a").path))
        let decoder = Process()
        decoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        decoder.arguments = ["-v", "error", "-i", channelsFolder.appendingPathComponent("meeting.m4a").path,
                             "-c:a", "pcm_s16le", channelsFolder.appendingPathComponent("check.wav").path]
        try decoder.run()
        decoder.waitUntilExit()
        precondition(decoder.terminationStatus == 0)
        let mixed = try AVAudioFile(forReading: channelsFolder.appendingPathComponent("check.wav"))
        let buffer = AVAudioPCMBuffer(pcmFormat: mixed.processingFormat, frameCapacity: AVAudioFrameCount(mixed.length))!
        try mixed.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        precondition(abs(Double(mixed.length) / mixed.processingFormat.sampleRate - 0.6) < 0.001)
        for (time, expected) in [(0.05, 0.25), (0.15, 0.125), (0.25, 0.0), (0.35, 0.125), (0.55, 0.125)] {
            let value = Double(samples[Int(time * mixed.processingFormat.sampleRate)])
            precondition(abs(value - expected) < 0.001, "Mixed timeline mismatch at \(time): \(value)")
        }
        print("PASS: independent channel pause, shared timeline, global pause interaction, export after interrupted capture")
        print("PASS: native PCM capture, separate formats/tracks, CAF writing, pause clock, compact timeline, repeated pauses and stop while paused")
    }
}
