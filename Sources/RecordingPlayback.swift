import AVFoundation
import Foundation
import SwiftUI

struct PlaybackCue: Identifiable, Equatable {
    var id: Int
    let start: Double
    let end: Double
    let text: String
}

enum PlaybackTranscript {
    static func parseSRT(_ text: String) -> [PlaybackCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [PlaybackCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains(" --> ") }), index + 1 < lines.count else { continue }
            let times = lines[index].components(separatedBy: " --> ")
            guard times.count == 2, let start = seconds(times[0]), let end = seconds(times[1]), end > start else { continue }
            let body = lines[(index + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(PlaybackCue(id: cues.count, start: start, end: end, text: body))
        }
        return ordered(cues)
    }

    private static func seconds(_ text: String) -> Double? {
        let pieces = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard pieces.count == 3, let h = Double(pieces[0]), let m = Double(pieces[1]), let s = Double(pieces[2]),
              h.isFinite, m.isFinite, s.isFinite, h >= 0, m >= 0, m < 60, s >= 0, s < 60 else { return nil }
        return h * 3600 + m * 60 + s
    }

    private static func ordered(_ cues: [PlaybackCue]) -> [PlaybackCue] {
        cues.sorted { $0.start < $1.start }.enumerated().map {
            PlaybackCue(id: $0.offset, start: $0.element.start, end: $0.element.end, text: $0.element.text)
        }
    }

    static func load(audio: URL) throws -> [PlaybackCue] {
        let srt = audio.deletingPathExtension().appendingPathExtension("srt")
        let directory = audio.deletingLastPathComponent()
        let named = directory.appendingPathComponent("speakers.json")
        let hasNames = FileManager.default.fileExists(atPath: named.path)
        if !hasNames && FileManager.default.fileExists(atPath: srt.path) {
            return parseSRT(try String(contentsOf: srt, encoding: .utf8))
        }
        // Older recordings can have confirmed captions without an exported SRT.
        let journal = audio.deletingLastPathComponent().appendingPathComponent("captions.jsonl")
        guard FileManager.default.fileExists(atPath: journal.path) else {
            return FileManager.default.fileExists(atPath: srt.path) ? parseSRT(try String(contentsOf: srt, encoding: .utf8)) : []
        }
        let record = hasNames ? try JSONDecoder().decode(SpeakerRecord.self, from: Data(contentsOf: named)) : nil
        let turnURL = directory.appendingPathComponent("speaker-turns.jsonl")
        let turns: [SpeakerTurn] = hasNames && FileManager.default.fileExists(atPath: turnURL.path)
            ? try String(contentsOf: turnURL, encoding: .utf8).split(separator: "\n").compactMap {
                try? JSONDecoder().decode(SpeakerTurn.self, from: Data($0.utf8))
            } : []
        let lines = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n")
        let cues = lines.flatMap { line -> [PlaybackCue] in
            guard let cue = try? JSONDecoder().decode(CaptionCue.self, from: Data(line.utf8)),
                  cue.start.isFinite, cue.end.isFinite, cue.start >= 0, cue.end > cue.start, !cue.text.isEmpty else { return [] }
            return cue.splitBySpeaker(turns: turns).map { cue in
                let label = record.map { VoiceIdentity.label(track: cue.track, start: cue.start, end: cue.end, turns: turns, speakers: $0.speakers) }
                    ?? (cue.track == "microphone" ? "我" : "会议对方")
                return PlaybackCue(id: 0, start: cue.start, end: cue.end, text: label + "：" + cue.text)
            }
        }
        return ordered(cues)
    }

    static func active(in cues: [PlaybackCue], at position: Double) -> [PlaybackCue] {
        cues.filter { $0.start <= position && position < $0.end }
    }

    static func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
}

@MainActor final class RecordingPlayback: ObservableObject {
    @Published var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var playing = false
    @Published private(set) var ready = false
    @Published private(set) var cues: [PlaybackCue] = []
    @Published private(set) var error = ""
    @Published private(set) var captionWarning = ""
    @Published var speed: Float = 1 { didSet { if playing { player?.rate = speed } } }
    @Published var followPlayback = true
    @Published var fontSize = 26.0
    var scrubbing = false
    private let audio: URL
    private var player: AVPlayer?
    private var observer: Any?
    private var endedObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var closed = false

    init(audio: URL) { self.audio = audio }

    var activeCues: [PlaybackCue] { PlaybackTranscript.active(in: cues, at: position) }
    var focusedCue: PlaybackCue? { activeCues.first }

    func load(autoplay: Bool = true) async {
        guard player == nil, !closed else { return }
        let item = AVPlayerItem(url: audio)
        let player = AVPlayer(playerItem: item)
        self.player = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.closed, !self.scrubbing, time.seconds.isFinite else { return }
                self.position = time.seconds
            }
        }
        endedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.playing = false }
        }
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "无法读取录音文件"
            Task { @MainActor in self?.error = "播放失败：\(message)"; self?.playing = false; self?.ready = false }
        }
        do {
            async let length = item.asset.load(.duration)
            let audio = self.audio
            let captions = await Task.detached { () -> ([PlaybackCue], String) in
                do { return (try PlaybackTranscript.load(audio: audio), "") }
                catch { return ([], "字幕暂时无法读取，仍可播放录音。") }
            }.value
            let seconds = try await length.seconds
            guard !closed else { return }
            guard seconds.isFinite, seconds > 0 else { throw NSError(domain: "Playback", code: 1, userInfo: [NSLocalizedDescriptionKey: "录音时长无效"]) }
            duration = seconds; cues = captions.0; captionWarning = captions.1
            ready = true
            if autoplay { toggle() }
        } catch {
            if !closed { self.error = "无法播放录音：\(error.localizedDescription)" }
        }
    }

    func toggle() {
        guard ready, let player else { return }
        if playing { player.pause(); playing = false }
        else {
            if position >= duration - 0.1 { seek(to: 0) }
            player.playImmediately(atRate: speed); playing = true
        }
    }

    func seek(to value: Double) {
        guard ready else { return }
        position = min(duration, max(0, value))
        player?.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func close() {
        closed = true; player?.pause(); playing = false
        if let observer { player?.removeTimeObserver(observer) }
        if let endedObserver { NotificationCenter.default.removeObserver(endedObserver) }
        statusObserver = nil; observer = nil; endedObserver = nil; player = nil
    }
}
