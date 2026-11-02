import Foundation
import AVFoundation


final class SpeakerTests {
    func testCleanSpeakerEvidence() {
        var tracker = LiveSpeakerClusters()
        XCTAssertNil(tracker.observe([1, 0, 0], seconds: 0.5))
        XCTAssertEqual(tracker.observe([1, 0, 0], seconds: 2)?.confirmed, false)
        XCTAssertEqual(tracker.observe([1, 0, 0], seconds: 2)?.confirmed, false)
        XCTAssertEqual(tracker.observe([1, 0, 0], seconds: 2)?.confirmed, true)
        XCTAssertEqual(tracker.observe([0, 1, 0], seconds: 3)?.confirmed, false)
        _ = tracker.observe([0, 1, 0], seconds: 3)
        XCTAssertEqual(tracker.observe([0, 1, 0], seconds: 3)?.id, 2)
        XCTAssertEqual(tracker.observe([1, 0, 0], seconds: 3)?.id, 1)
        XCTAssertNil(tracker.observe([1, 1, 0], seconds: 3)) // Ambiguous, not forced onto person 1.
        XCTAssertNil(tracker.observe([0, 0, 1], seconds: 1)) // Short unfamiliar voice cannot enroll.
        XCTAssertEqual(tracker.clusters.count, 2)
        var sporadic = LiveSpeakerClusters()
        for t in [0.0, 30, 60, 90] {
            XCTAssertEqual(sporadic.observe([1, 0], seconds: 3, at: t)?.confirmed, false)
        }
        XCTAssertEqual(sporadic.observe([1, 0], seconds: 3, at: 94)?.confirmed, false)
        XCTAssertEqual(sporadic.observe([1, 0], seconds: 3, at: 98)?.confirmed, true)
        #if canImport(FluidAudio)
        let frames: [[Float]] = [[1,0], [1,0], [1,1], [0,1], [0,1], [1,0]]
        XCTAssertEqual(CleanSpeakerAnalyzer.cleanRanges(frames: frames, speaker: 0, sampleCount: 1200), [0..<540])
        XCTAssertEqual(CleanSpeakerAnalyzer.cleanRanges(frames: frames, speaker: 1, sampleCount: 1200), [810..<1200])
        #endif
    }
    func testMatchingRejectsAmbiguityDifferentModelAndInvalidVectors() {
        let a = VoicePerson(id: "a", name: "张三", model: "v1", samples: [[1, 0]])
        let b = VoicePerson(id: "b", name: "李四", model: "v1", samples: [[0.99, 0.01]])
        XCTAssertEqual(VoiceIdentity.match([1, 0], people: [a], model: "v1")?.id, "a")
        XCTAssertNil(VoiceIdentity.match([1, 0], people: [a, b], model: "v1"))
        XCTAssertNil(VoiceIdentity.match([1, 0], people: [a], model: "v2"))
        XCTAssertNil(VoiceIdentity.match([.nan, 0], people: [a], model: "v1"))
        XCTAssertNil(VoiceIdentity.match([1, 0, 0], people: [a], model: "v1"))
    }
    func testCrossMeetingRequiresRepeatedDistinctEvidence() {
        let a = VoicePerson(id: "a", name: "张三", model: "v2", samples: [[1, 0, 0]])
        let voice: [Float] = [0.6, 0.8, 0]
        var evidence = SpeakerMatchEvidence()
        XCTAssertNil(evidence.observe(voice, seconds: 3, people: [a], model: "v2"))
        XCTAssertNil(evidence.observe(voice, seconds: 3, people: [a], model: "v2"))
        XCTAssertEqual(evidence.observe(voice, seconds: 3, people: [a], model: "v2")?.id, "a")
        XCTAssertNil(evidence.observe([0, 0, 1], seconds: 3, people: [a], model: "v2"))
        XCTAssertNil(evidence.observe(voice, seconds: 3, people: [a], model: "v2"))
        let b = VoicePerson(id: "b", name: "李四", model: "v2", samples: [[0.99, 0.01, 0]])
        for _ in 0..<5 {
            XCTAssertNil(evidence.observe(voice, seconds: 3, people: [a, b], model: "v2"))
            XCTAssertNil(evidence.observe(voice, seconds: 3, people: [a], model: "other"))
        }
        var short = SpeakerMatchEvidence()
        for _ in 0..<3 { XCTAssertNil(short.observe(voice, seconds: 1.5, people: [a], model: "v2")) }
        XCTAssertEqual(short.observe(voice, seconds: 1.5, people: [a], model: "v2")?.id, "a")
    }
    func testSidesAndMixedUtterances() {
        let speakers = [MeetingSpeaker(id: "m", track: "microphone", number: 1, embedding: [], name: "张三"),
                        MeetingSpeaker(id: "s", track: "system", number: 1, embedding: [], name: "李四")]
        var turns = [SpeakerTurn(track: "microphone", speakerID: "m", start: 0, end: 4),
                     SpeakerTurn(track: "system", speakerID: "s", start: 0, end: 4)]
        XCTAssertEqual(VoiceIdentity.label(track: "system", start: 0, end: 4, turns: turns, speakers: speakers), "会议方 · 李四")
        XCTAssertEqual(VoiceIdentity.label(track: "microphone", start: 0, end: 4, turns: turns, speakers: speakers), "我方 · 张三")
        turns.append(SpeakerTurn(track: "system", speakerID: "other", start: 0, end: 4))
        XCTAssertEqual(VoiceIdentity.label(track: "system", start: 0, end: 4, turns: turns, speakers: speakers), "会议方 · 多人/待确认")
    }
    @MainActor func testEnrollmentSurvivesRestartAndDoesNotEnrollAutomaticMatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        SpeakerController.rootOverride = root.appendingPathComponent("library")
        defer { SpeakerController.rootOverride = nil; try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("meeting")
        let record = SpeakerRecord(model: "fixture-v1", speakers: [MeetingSpeaker(id: "system:a", track: "system", number: 1, embedding: [1, 0], speechSeconds: 5)])
        try VoiceIdentity.write(record, to: folder.appendingPathComponent("speakers.json"))
        try Data().write(to: folder.appendingPathComponent("speaker-turns.jsonl"))
        let first = SpeakerController(); first.open(folder)
        first.annotate(id: "system:a", name: "张三", remember: true)
        XCTAssertEqual(first.people.count, 1)
        first.annotate(id: "system:a", name: "张三", remember: true)
        XCTAssertEqual(first.people.count, 1) // Repeated confirmation must not create ambiguous duplicates.
        let second = SpeakerController(); second.open(folder)
        XCTAssertEqual(second.people.first?.name, "张三")
        XCTAssertEqual(second.speakers.first?.name, "张三")
        XCTAssertEqual(VoiceIdentity.match([1, 0], people: second.people, model: "fixture-v1")?.name, "张三")
        second.forget(second.people[0].id)
        XCTAssertTrue(SpeakerController().people.isEmpty)
        XCTAssertEqual(second.speakers.first?.name, "张三")
    }
    @MainActor func testCrossMeetingControllerUsesIndependentWindows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        SpeakerController.rootOverride = root.appendingPathComponent("library")
        defer { SpeakerController.rootOverride = nil; try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try VoiceIdentity.write(SpeakerRecord(model: "fixture", speakers: [
            MeetingSpeaker(id: "system:1", track: "system", number: 1, embedding: [1, 0], speechSeconds: 6)
        ]), to: first.appendingPathComponent("speakers.json"))
        try Data().write(to: first.appendingPathComponent("speaker-turns.jsonl"))
        let enrollment = SpeakerController(); enrollment.open(first)
        enrollment.annotate(id: "system:1", name: "张三", remember: true)
        try VoiceIdentity.write(SpeakerRecord(model: "fixture"), to: second.appendingPathComponent("speakers.json"))
        try Data().write(to: second.appendingPathComponent("speaker-turns.jsonl"))
        let controller = SpeakerController(); controller.open(second)
        func update(_ start: Double) -> SpeakerUpdate {
            SpeakerUpdate(turn: SpeakerTurn(track: "system", speakerID: "system:2", start: start, end: start + 2),
                          embedding: [0.6, 0.8])
        }
        controller.receive([update(0), update(2), update(4)], error: nil)
        XCTAssertNil(controller.speakers.first?.name) // One callback cannot cast three votes.
        controller.receive([update(6)], error: nil)
        XCTAssertNil(controller.speakers.first?.name)
        controller.receive([update(8)], error: nil)
        XCTAssertEqual(controller.speakers.first?.name, "张三")
        XCTAssertEqual(controller.speakers.first?.confirmed, false)
        XCTAssertEqual(SpeakerController().people.first?.samples.count, 1)
        let reloaded = SpeakerController(); reloaded.open(second)
        XCTAssertEqual(reloaded.speakers.first?.name, "张三")
        controller.annotate(id: "system:2", name: "本场姓名", remember: false)
        controller.receive([update(10)], error: nil)
        XCTAssertEqual(controller.speakers.first?.name, "本场姓名")
    }

    func testModelImportIsTransactional() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("download/speaker-diarization-coreml")
        let destination = root.appendingPathComponent("installed")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("old-model"))
        for name in SpeakerModelFiles.bundles {
            let bundle = source.appendingPathComponent(name)
            try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: bundle.appendingPathComponent("coremldata.bin"))
        }
        do {
            try SpeakerModelFiles.install(from: source, to: destination) { _ in throw problem("invalid model") }
            preconditionFailure("Invalid import succeeded")
        } catch {}
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent("old-model").path))
        try Data("untrusted".utf8).write(to: source.appendingPathComponent("identity.txt"))
        try Data("private".utf8).write(to: source.appendingPathComponent("people.json"))
        try SpeakerModelFiles.install(from: source.deletingLastPathComponent(), to: destination) { _ in }
        XCTAssertTrue(!fm.fileExists(atPath: destination.appendingPathComponent("people.json").path))
        let identity = try String(contentsOf: destination.appendingPathComponent("identity.txt"), encoding: .utf8)
        XCTAssertEqual(identity, try SpeakerModelFiles.fingerprint(destination))
        try SpeakerModelFiles.install(from: destination, to: destination) { _ in }
        XCTAssertEqual(identity, try String(contentsOf: destination.appendingPathComponent("identity.txt"), encoding: .utf8))
        let legacyID = String(repeating: "a", count: 64)
        try legacyID.write(to: destination.appendingPathComponent("identity.txt"), atomically: true, encoding: .utf8)
        try SpeakerModelFiles.install(from: source, to: destination) { _ in }
        XCTAssertEqual(legacyID, try String(contentsOf: destination.appendingPathComponent("identity.txt"), encoding: .utf8))
        try fm.removeItem(at: source.appendingPathComponent(SpeakerModelFiles.bundles[0]))
        do {
            try SpeakerModelFiles.install(from: source, to: destination) { _ in }
            preconditionFailure("Incomplete import succeeded")
        } catch {}
        XCTAssertEqual(legacyID, try String(contentsOf: destination.appendingPathComponent("identity.txt"), encoding: .utf8))
    }

    @MainActor func testRealModelImport() async throws {
        guard let source = ProcessInfo.processInfo.environment["SPEAKER_IMPORT_TEST_SOURCE"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        SpeakerController.rootOverride = root
        defer { SpeakerController.rootOverride = nil; try? FileManager.default.removeItem(at: root) }
        let controller = SpeakerController()
        await controller.importModels(from: URL(fileURLWithPath: source))
        XCTAssertTrue(controller.ready, controller.status)
        XCTAssertTrue(!controller.importing)
        XCTAssertEqual(try SpeakerModelFiles.fingerprint(SpeakerController.models),
                       try SpeakerModelFiles.fingerprint(URL(fileURLWithPath: source)))
        print("PASS: real Core ML models imported and fingerprint preserved")
    }

    // Explicit opt-in: uses only generated audio, no microphone or system capture.
    @MainActor func testRealModelsAndBoundedDualTrackPipeline() async throws {
        guard let path = ProcessInfo.processInfo.environment["SPEAKER_MODEL_TEST_ROOT"] else { print("SKIP: real models (set SPEAKER_MODEL_TEST_ROOT)"); return }
        SpeakerController.rootOverride = URL(fileURLWithPath: path)
        defer { SpeakerController.rootOverride = nil }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).appendingPathComponent("people.json"))
        let controller = SpeakerController()
        if !controller.ready { await controller.download() }
        XCTAssertTrue(controller.ready, controller.status)
        guard controller.ready else { return }
        let directory = URL(fileURLWithPath: path).appendingPathComponent("fixture-meeting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = controller.enabled
        controller.enabled = true
        defer { controller.enabled = previous }
        try await controller.start(folder: directory)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path).appendingPathComponent("fixture.aiff"))
        let receiver = try XCTUnwrap(controller.audioReceiver)
        var frames: AVAudioFramePosition = 0
        while frames < file.length * 2 {
            if file.framePosition >= file.length { file.framePosition = 0 }
            let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            try file.read(into: pcm)
            let time = Double(frames) / file.processingFormat.sampleRate
            receiver(pcm, "microphone", time); receiver(pcm, "system", time)
            frames += AVAudioFramePosition(pcm.frameLength)
            // Feed near realtime, with no recording permissions or playback.
            try await Task.sleep(nanoseconds: UInt64(Double(pcm.frameLength) / file.processingFormat.sampleRate * 1_000_000_000))
        }
        await controller.finish()
        XCTAssertTrue(controller.speakers.filter { $0.track == "microphone" }.count >= 2, controller.status)
        XCTAssertTrue(controller.speakers.filter { $0.track == "system" }.count >= 2, controller.status)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("speaker-turns.jsonl").path))
        print("Speaker pipeline smoke: \(controller.speakers.count) speakers, \(Double(frames) / file.processingFormat.sampleRate)s per track; \(controller.status)")
        let enrolled = try XCTUnwrap(controller.speakers.first { $0.track == "microphone" && $0.speechSeconds >= 3 })
        controller.annotate(id: enrolled.id, name: "测试张三", remember: true)
        XCTAssertEqual(controller.people.count, 1)
        let second = SpeakerController()
        let secondFolder = directory.appendingPathComponent("second-recording")
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        try await second.start(folder: secondFolder)
        let secondReceiver = try XCTUnwrap(second.audioReceiver)
        file.framePosition = 0; frames = 0
        while frames < file.length * 2 {
            if file.framePosition >= file.length { file.framePosition = 0 }
            let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            try file.read(into: pcm)
            let time = Double(frames) / file.processingFormat.sampleRate
            secondReceiver(pcm, "microphone", time); secondReceiver(pcm, "system", time)
            frames += AVAudioFramePosition(pcm.frameLength)
            try await Task.sleep(nanoseconds: UInt64(Double(pcm.frameLength) / file.processingFormat.sampleRate * 1_000_000_000))
        }
        await second.finish()
        XCTAssertTrue(second.speakers.contains { $0.name == "测试张三" && $0.track == "microphone" }, second.status)
        XCTAssertTrue(second.speakers.contains { $0.name == "测试张三" && $0.track == "system" }, second.status)
        print("PASS: real voice enrollment recognized in a new recording on both sides")
    }
}

func XCTAssertTrue(_ value: Bool, _ message: String = "") { precondition(value, message) }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b, "\(a) != \(b)") }
func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
func XCTUnwrap<T>(_ value: T?) throws -> T { guard let value else { throw problem("Unexpected nil") }; return value }
func problem(_ message: String) -> NSError { NSError(domain: "SpeakerTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
@main struct SpeakerSmoke {
    @MainActor static func main() async throws {
        let tests = SpeakerTests()
        tests.testCleanSpeakerEvidence()
        tests.testMatchingRejectsAmbiguityDifferentModelAndInvalidVectors()
        tests.testSidesAndMixedUtterances()
        tests.testCrossMeetingRequiresRepeatedDistinctEvidence()
        try tests.testModelImportIsTransactional()
        try tests.testCrossMeetingControllerUsesIndependentWindows()
        try await tests.testRealModelImport()
        try tests.testEnrollmentSurvivesRestartAndDoesNotEnrollAutomaticMatches()
        try await tests.testRealModelsAndBoundedDualTrackPipeline()
        print("PASS: identity, model isolation, ambiguity, side labels, enrollment persistence and deletion")
    }
}
