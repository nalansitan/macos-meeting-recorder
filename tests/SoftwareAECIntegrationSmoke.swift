import AVFoundation
import ScreenCaptureKit
import Foundation

@main struct SoftwareAECIntegrationSmoke {
    static func sample(_ values: [Float], rate: Double = 48000, channels: AVAudioChannelCount = 1, time: Double) -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
        pcm.frameLength = AVAudioFrameCount(values.count)
        for channel in 0..<Int(channels) { pcm.floatChannelData![channel].update(from: values, count: values.count) }
        var description: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        precondition(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: description, sampleCount: values.count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result) == noErr)
        precondition(CMSampleBufferSetDataBufferFromAudioBufferList(result!, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList) == noErr)
        precondition(CMSampleBufferSetDataReady(result!) == noErr)
        return result!
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("software-aec-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = 100.0
        func sink(_ name: String) throws -> AudioSink {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            return try AudioSink(folder: directory, softwareEchoCancellation: true, clock: { now })
        }
        let timeline = try sink("timeline")
        var starts = [Double](), count = 0
        timeline.onAudio = { pcm, track, time in
            if track == "microphone" { starts.append(time); count += Int(pcm.frameLength) }
        }
        timeline.receive(sample([Float](repeating: 0.2, count: 4800), time: 100.2), type: .microphone)
        now = 100.3; try timeline.setPaused(true)
        precondition(count == 4800, "Pause must drain pending microphone tail")
        timeline.receive(sample([Float](repeating: 0.2, count: 4800), time: 100.4), type: .microphone)
        now = 110.3; try timeline.setPaused(false)
        timeline.receive(sample([Float](repeating: 0.2, count: 4800), time: 109), type: .microphone)
        timeline.receive(sample([Float](repeating: 0.2, count: 4800), time: 110.4), type: .microphone)
        now = 110.5; try timeline.finish()
        precondition(count == 9600 && abs(starts.first! - 0.2) < 0.0001 && starts.contains(where: { abs($0 - 0.4) < 0.0001 }))
        precondition(timeline.manifest.state == "completed" && timeline.manifest.microphoneProcessing == "webrtcAEC3")
        let restored = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: timeline.folder.appendingPathComponent("meeting.json")))
        precondition(restored.microphoneProcessing == "webrtcAEC3")
        let writtenSamples = try restored.fragments.filter { $0.track == "microphone" }.reduce(0) {
            $0 + Int(try AVAudioFile(forReading: timeline.folder.appendingPathComponent($1.file)).length)
        }
        precondition(writtenSamples == 9600)

        now = 100
        let pausedReference = try sink("paused-system")
        try pausedReference.setTrackPaused("system", true)
        var inputEnergy = 0.0, outputEnergy = 0.0
        pausedReference.onAudio = { pcm, track, time in
            precondition(track == "microphone", "Paused system track must not be saved or transcribed")
            if time >= 5 && time < 8 {
                for i in 0..<Int(pcm.frameLength) { outputEnergy += Double(pcm.floatChannelData![0][i]) * Double(pcm.floatChannelData![0][i]) }
            }
        }
        var seed: UInt64 = 56
        var far = [Float](repeating: 0, count: 48000 * 9)
        var filtered: Float = 0
        for i in far.indices {
            seed = seed &* 6364136223846793005 &+ 1
            filtered = filtered * 0.8 + Float(Double(seed >> 32) / Double(UInt32.max) * 2 - 1) * 0.1
            far[i] = filtered
        }
        for frame in 0..<900 {
            let start = frame * 480, end = start + 480
            let mic = (start..<end).map { $0 >= 1920 ? far[$0 - 1920] * 0.6 : 0 }
            if frame >= 500 && frame < 800 { inputEnergy += mic.reduce(0) { $0 + Double($1) * Double($1) } }
            pausedReference.receive(sample(Array(far[start..<end]), time: 100 + Double(frame) / 100), type: .audio)
            pausedReference.receive(sample(mic, time: 100 + Double(frame) / 100), type: .microphone)
        }
        now = 109; try pausedReference.finish()
        let reduction = 10 * log10(inputEnergy / max(outputEnergy, 1e-20))
        precondition(reduction > 12 && !pausedReference.manifest.fragments.contains(where: { $0.track == "system" }))
        print(String(format: "Paused system-save still supplies AEC reference: %.1f dB reduction", reduction))

        now = 100
        let resampled = try sink("resampled")
        var resampledCount = 0
        var resampledEnergy = 0.0
        resampled.onAudio = { pcm, track, _ in
            guard track == "microphone" else { return }
            precondition(pcm.format.sampleRate == 48000 && pcm.format.channelCount == 1)
            resampledCount += Int(pcm.frameLength)
            for i in 0..<Int(pcm.frameLength) { resampledEnergy += Double(pcm.floatChannelData![0][i]) * Double(pcm.floatChannelData![0][i]) }
        }
        for frame in 0..<100 {
            let values = (0..<441).map { Float(sin(2 * Double.pi * 440 * Double(frame * 441 + $0) / 44100)) * 0.2 }
            resampled.receive(sample(values, rate: 44100, channels: 2, time: 100 + Double(frame) / 100), type: .microphone)
        }
        now = 101; try resampled.finish()
        print("44.1 kHz stereo -> 48 kHz mono: \(resampledCount) samples")
        precondition(resampledCount == 48000 && resampledEnergy > 800 && resampledEnergy < 1100)
        precondition(resampled.manifest.state == "completed")
        now = 100
        let pausedMicrophone = try sink("paused-microphone")
        var micSamples = 0
        pausedMicrophone.onAudio = { buffer, track, _ in
            if track == "microphone" { micSamples += Int(buffer.frameLength) }
        }
        pausedMicrophone.receive(sample([Float](repeating: 0.2, count: 4800), time: 100.2), type: .microphone)
        now = 100.3; try pausedMicrophone.setTrackPaused("microphone", true)
        precondition(micSamples == 4800)
        pausedMicrophone.receive(sample([Float](repeating: 0.9, count: 4800), time: 100.4), type: .microphone)
        now = 100.5; try pausedMicrophone.setTrackPaused("microphone", false)
        pausedMicrophone.receive(sample([Float](repeating: 0.2, count: 4800), time: 100.6), type: .microphone)
        now = 100.7; try pausedMicrophone.finish()
        precondition(micSamples == 9600, "Single-track pause must preserve prior tail and reject paused packets")

        // Bad timestamps report an error and close files instead of recursively
        // entering the processor or leaving the capture lock behind.
        now = 100
        let invalid = try sink("invalid")
        invalid.receive(sample([Float](repeating: 0, count: 480), time: .nan), type: .microphone)
        precondition(invalid.finished && invalid.manifest.state == "interrupted")
        print("PASS: ScreenCaptureKit-buffer integration, pause/resume, stale input, final CAF, AEC reference while system-save paused, stereo resampling and invalid timestamp failure; no audio devices used")
    }
}
