import AVFoundation
import Foundation

// Uses a local synthesized fixture, never requests microphone capture or model installation.
@main struct CaptionPipelineSmoke {
    @MainActor static func main() async throws {
        guard #available(macOS 26.0, *) else { throw problem("macOS 26 required") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let folder = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let locale = try await OfflineCaptionSession.checkLocale("zh_CN")
        var sawLiveText = false
        let session = try OfflineCaptionSession(folder: folder, locale: locale) { text, status in
            if !text.isEmpty { sawLiveText = true }
            if status.contains("失败") { print(status) }
        }
        try await session.start()
        let receiver = session.audioReceiver
        let file = try AVAudioFile(forReading: fixture)
        precondition(file.length > 0, "Fixture contains no audio")
        var frame: AVAudioFramePosition = 0
        while frame < file.length {
            let count = AVAudioFrameCount(min(4800, file.length - frame))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
            try file.read(into: buffer)
            let time = Double(frame) / file.processingFormat.sampleRate
            receiver(buffer, "microphone", time)
            receiver(buffer, "system", time + 2)
            frame += AVAudioFramePosition(buffer.frameLength)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(2))
        precondition(sawLiveText, "No live text before finishing input")
        await session.finish()
        let lines = try String(contentsOf: folder.appendingPathComponent("captions.jsonl"), encoding: .utf8)
        let cues = try lines.split(separator: "\n").map { try JSONDecoder().decode(CaptionCue.self, from: Data($0.utf8)) }
        precondition(cues.contains { $0.track == "microphone" && !$0.text.isEmpty }, "Missing microphone final results")
        precondition(cues.contains { $0.track == "system" && $0.start >= 2 && !$0.text.isEmpty }, "Missing shifted system results")
        let status = try String(contentsOf: folder.appendingPathComponent("captions-status.json"), encoding: .utf8)
        precondition(status.contains("completed"), status)
        print("PASS: simultaneous offline Chinese transcribers, resampling, final flush, speaker sources, shifted timestamps, durable journal")
        print(lines)
        let emptyFolder = folder.appendingPathComponent("no-audio")
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        let empty = try OfflineCaptionSession(folder: emptyFolder, locale: locale) { _, _ in }
        try await empty.start()
        await empty.finish()
        let emptyStatus = try String(contentsOf: emptyFolder.appendingPathComponent("captions-status.json"), encoding: .utf8)
        precondition(emptyStatus.contains("completed"), emptyStatus)
        print("PASS: no-audio shutdown does not report a spurious recognition failure")

        let silentFolder = folder.appendingPathComponent("silence")
        try FileManager.default.createDirectory(at: silentFolder, withIntermediateDirectories: true)
        var silentText = ""
        let silent = try OfflineCaptionSession(folder: silentFolder, locale: locale) { text, _ in silentText = text }
        try await silent.start()
        let silenceFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let silentReceiver = silent.audioReceiver
        for index in 0..<120 {
            let buffer = AVAudioPCMBuffer(pcmFormat: silenceFormat, frameCapacity: 4800)!
            buffer.frameLength = 4800
            buffer.floatChannelData![0].initialize(repeating: 0, count: 4800)
            silentReceiver(buffer, "microphone", Double(index) / 10)
            silentReceiver(buffer, "system", Double(index) / 10)
            try await Task.sleep(for: .milliseconds(10))
        }
        await silent.finish()
        let silentLines = try Data(contentsOf: silentFolder.appendingPathComponent("captions.jsonl"))
        let silentStatus = try String(contentsOf: silentFolder.appendingPathComponent("captions-status.json"), encoding: .utf8)
        precondition(silentText.isEmpty && silentLines.isEmpty && silentStatus.contains("completed"), silentStatus)
        print("PASS: dual-lane silence produces no invented transcript")
    }
}
