import Foundation
import AVFoundation
import CoreML
import FluidAudio

// Read-only regression replay. No microphone capture, playback, enrollment or
// writes to the source meeting. Audio memory is bounded to a few CAF fragments.
@main struct SpeakerReplay {
    struct Fragment: Decodable { var file: String; var track: String; var start: Double }
    struct Manifest: Decodable { var fragments: [Fragment] }
    struct Chunk { var samples: [Float]; var track: String; var start: Double }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { throw problem("Usage: replay RECORDING OUTPUT_JSON [SYSTEM_COUNT MIC_COUNT]") }
        let directory = URL(fileURLWithPath: args[1])
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SPEAKER_MODELS"] ??
            NSHomeDirectory() + "/Library/Application Support/MeetingRecorder/Speakers/speaker-diarization")
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine
        let models = try DiarizerModels.load(localSegmentationModel: root.appendingPathComponent("pyannote_segmentation.mlmodelc"),
            localEmbeddingModel: root.appendingPathComponent("wespeaker_v2.mlmodelc"), configuration: config)
        let analyzer = CleanSpeakerAnalyzer(models: models)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("meeting.json")))
        var pending: [Chunk] = [], tails: [String: Chunk] = [:], turns: [SpeakerTurn] = []
        func drain(before time: Double) throws {
            let ready = pending.filter { $0.start + Double($0.samples.count) / 16000 <= time }.sorted { $0.start < $1.start }
            pending.removeAll { $0.start + Double($0.samples.count) / 16000 <= time }
            for chunk in ready {
                turns += try analyzer.analyze(chunk.samples, track: chunk.track, start: chunk.start).map(\.turn)
            }
        }
        for fragment in manifest.fragments.sorted(by: { $0.start < $1.start }) {
            try drain(before: fragment.start)
            let file = try AVAudioFile(forReading: directory.appendingPathComponent(fragment.file))
            let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: input)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let converter = AVAudioConverter(from: input.format, to: format)!
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 16000 / input.format.sampleRate) + 64)!
            var supplied = false; var error: NSError?
            converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if let error { throw error }
            var tail = tails[fragment.track] ?? Chunk(samples: [], track: fragment.track, start: fragment.start)
            if abs(tail.start + Double(tail.samples.count) / 16000 - fragment.start) > 0.08 {
                if tail.samples.count >= 8000 { pending.append(tail) }
                tail = Chunk(samples: [], track: fragment.track, start: fragment.start)
            }
            tail.samples += Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            while tail.samples.count >= 64000 {
                pending.append(Chunk(samples: Array(tail.samples.prefix(64000)), track: fragment.track, start: tail.start))
                tail.samples.removeFirst(64000); tail.start += 4
            }
            tails[fragment.track] = tail
        }
        pending += tails.values.filter { $0.samples.count >= 8000 }
        try drain(before: .infinity)
        try JSONEncoder().encode(turns).write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        let system = Set(turns.filter { $0.track == "system" }.map(\.speakerID)).count
        let microphone = Set(turns.filter { $0.track == "microphone" }.map(\.speakerID)).count
        print("Replay: system=\(system), microphone=\(microphone), turns=\(turns.count)")
        if args.count >= 5 {
            guard system == Int(args[3]), microphone == Int(args[4]) else { throw problem("Speaker count regression failed") }
        }
    }
}
func problem(_ message: String) -> NSError { NSError(domain: "SpeakerReplay", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
