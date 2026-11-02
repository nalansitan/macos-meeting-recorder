import Foundation

@main struct PlaybackSmoke {
    @MainActor static func main() async throws {
        let srt = "1\r\n00:00:00,500 --> 00:00:01,500\r\n我：确认进度\r\n会议对方：好的\r\n\r\n2\r\n00:00:02,000 --> 00:00:03,000\r\n会议对方：下一项\r\n"
        let cues = PlaybackTranscript.parseSRT(srt)
        precondition(cues.count == 2 && cues[0].start == 0.5 && cues[0].text.contains("\n会议对方"))
        precondition(PlaybackTranscript.active(in: cues, at: 0.499).isEmpty)
        precondition(PlaybackTranscript.active(in: cues, at: 0.5).first?.id == 0)
        precondition(PlaybackTranscript.active(in: cues, at: 1.5).isEmpty)
        precondition(PlaybackTranscript.active(in: cues, at: 2).first?.id == 1)
        let overlap = [cues[0], PlaybackCue(id: 2, start: 1, end: 2, text: "会议对方：同时发言")]
        precondition(PlaybackTranscript.active(in: overlap, at: 1.25).count == 2)
        precondition(PlaybackTranscript.parseSRT("1\n00:61:00,000 --> 01:00:00,000\n无效\n").isEmpty)
        precondition(PlaybackTranscript.time(1153.9) == "19:13" && PlaybackTranscript.time(3661) == "1:01:01")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("playback-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("meeting.m4a")
        let missing = try PlaybackTranscript.load(audio: audio)
        precondition(missing.isEmpty)
        try "{\"track\":\"microphone\",\"start\":1,\"end\":2,\"text\":\"测试\"}\n{broken".write(
            to: root.appendingPathComponent("captions.jsonl"), atomically: true, encoding: .utf8)
        let recovered = try PlaybackTranscript.load(audio: audio)
        precondition(recovered.count == 1 && recovered[0].text == "我：测试")
        try srt.write(to: root.appendingPathComponent("meeting.srt"), atomically: true, encoding: .utf8)
        let loaded = try PlaybackTranscript.load(audio: audio)
        precondition(loaded == cues)

        let speakers = [MeetingSpeaker(id: "a", track: "system", number: 1, embedding: [], name: "张三"),
                        MeetingSpeaker(id: "b", track: "system", number: 2, embedding: [], name: "李四")]
        let turns = [SpeakerTurn(track: "system", speakerID: "a", start: 0, end: 3),
                     SpeakerTurn(track: "system", speakerID: "b", start: 3, end: 4)]
        let timed = CaptionCue(track: "system", start: 0, end: 4, text: "说完了好的", tokens: [
            CaptionToken(start: 0, end: 3, text: "说完了"), CaptionToken(start: 3, end: 4, text: "好的")])
        precondition(timed.splitBySpeaker(turns: turns).map(\.text) == ["说完了", "好的"])
        precondition(timed.splitBySpeaker(turns: []).map(\.text) == ["说完了好的"])
        let crossing = CaptionCue(track: "system", start: 0, end: 4, text: "整词", tokens: [
            CaptionToken(start: 0, end: 4, text: "整词")])
        precondition(crossing.splitBySpeaker(turns: turns).count == 1)
        let foreignTurns = turns.map { SpeakerTurn(track: "microphone", speakerID: $0.speakerID, start: $0.start, end: $0.end) }
        precondition(timed.splitBySpeaker(turns: foreignTurns).count == 1)

        precondition(VoiceIdentity.label(track: "system", start: 0, end: 4, turns: turns, speakers: speakers).contains("多人/待确认"))
        try VoiceIdentity.write(SpeakerRecord(model: "test", speakers: speakers), to: root.appendingPathComponent("speakers.json"))
        try (turns.map { String(data: try JSONEncoder().encode($0), encoding: .utf8)! }.joined(separator: "\n"))
            .write(to: root.appendingPathComponent("speaker-turns.jsonl"), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(timed).write(to: root.appendingPathComponent("captions.jsonl"))
        let split = try PlaybackTranscript.load(audio: audio)
        precondition(split.count == 2 && split[0].text == "会议方 · 张三：说完了" && split[1].start == 3)
        // Rename metadata without changing timestamps or the original transcript.
        var renamed = speakers; renamed[1].name = "王五"
        try VoiceIdentity.write(SpeakerRecord(model: "test", speakers: renamed), to: root.appendingPathComponent("speakers.json"))
        let updated = try PlaybackTranscript.load(audio: audio)
        precondition(updated[1].text == "会议方 · 王五：好的")
        try FileManager.default.removeItem(at: root.appendingPathComponent("speakers.json"))

        // Use a silent fixture: no microphone access and no audible meeting playback.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: audio)
        let playback = RecordingPlayback(audio: audio)
        await playback.load(autoplay: false)
        precondition(playback.ready && playback.error.isEmpty && !playback.playing && playback.duration > 2.9)
        precondition(playback.cues == cues)
        playback.seek(to: 0.75)
        precondition(playback.focusedCue?.id == 0)
        playback.seek(to: -10); precondition(playback.position == 0)
        playback.seek(to: 999); precondition(playback.position == playback.duration)
        playback.toggle(); precondition(playback.playing && playback.position == 0)
        playback.speed = 1.5
        playback.toggle(); precondition(!playback.playing)
        playback.close(); precondition(!playback.playing)
        print("PASS: subtitle parsing, overlap, gaps, seek alignment, legacy captions, silent audio loading, replay, speed, pause and cleanup")
    }
}
