import AVFoundation
import Foundation

// Replay the two captured test files into the existing offline caption pipeline.
// No microphone access, network recognition or model installation.
@main struct AECRecognitionProbe {
    @MainActor static func main() async throws {
        guard #available(macOS 26.0, *) else { throw problem("macOS 26 required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let locale = try await OfflineCaptionSession.checkLocale("zh_CN")
        let names = CommandLine.arguments.contains("--near-end") ? ["near-baseline", "near-processed", "doubletalk-processed"] : ["baseline", "processed"]
        for name in names {
            let folder = root.appendingPathComponent(name + "-captions")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let session = try OfflineCaptionSession(folder: folder, locale: locale) { _, _ in }
            try await session.start()
            let file = try AVAudioFile(forReading: root.appendingPathComponent(name + ".caf"))
            let receive = session.audioReceiver
            var frame: AVAudioFramePosition = 0
            while frame < file.length {
                let count = AVAudioFrameCount(min(Int64(file.processingFormat.sampleRate / 10), file.length - frame))
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
                try file.read(into: buffer)
                receive(buffer, "microphone", Double(frame) / file.processingFormat.sampleRate)
                frame += AVAudioFramePosition(buffer.frameLength)
                try await Task.sleep(for: .milliseconds(100))
            }
            await session.finish()
            let status = try String(contentsOf: folder.appendingPathComponent("captions-status.json"), encoding: .utf8)
            let text = try String(contentsOf: folder.appendingPathComponent("captions.jsonl"), encoding: .utf8)
            print(name + " status: " + status)
            print(name + " captions: " + text)
        }
    }
}
