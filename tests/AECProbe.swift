import AppKit
import AVFoundation
import CoreAudio

// Standalone acoustic experiment. Never linked into the production recorder.
@MainActor final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    var nearEnd: Bool { CommandLine.arguments.contains("--near-end") }
    var output: URL { URL(fileURLWithPath: nearEnd ? "/tmp/meeting-recorder-aec-nearend" : "/tmp/meeting-recorder-aec-probe", isDirectory: true) }
    let label = NSTextField(wrappingLabelWithString: "正在准备回声消除测试，请先保持安静。")
    var window: NSWindow!
    var engine: AVAudioEngine?
    var activePlayback: Process?
    var changed = false
    var results: [[String: Any]] = []
    func deviceName(_ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return "unknown" }
        address.mSelector = kAudioObjectPropertyName
        let name = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        name.initialize(to: nil)
        defer { name.deinitialize(count: 1); name.deallocate() }
        size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, name) == noErr else { return "unknown" }
        return name.pointee.map { $0 as String } ?? "unknown"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "退出验证工具", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 280), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "会议录音 · 回声消除验证"
        label.frame = NSRect(x: 24, y: 30, width: 690, height: 220)
        label.font = .systemFont(ofSize: 18)
        window.contentView?.addSubview(label)
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await run() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
        if activePlayback?.isRunning == true { activePlayback?.terminate() }
    }

    func run() async {
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["state": "running"])
                .write(to: output.appendingPathComponent("result.json"), options: .atomic)
            let reference = try AVAudioFile(forReading: directory.appendingPathComponent("reference.aiff"))
            guard reference.length > 0, Double(reference.length) / reference.processingFormat.sampleRate < 20 else {
                throw NSError(domain: "AECProbe", code: 7, userInfo: [NSLocalizedDescriptionKey: "测试语音为空或过长，未启动麦克风采集。"])
            }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw NSError(domain: "AECProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "未获得麦克风权限，未执行测试。"])
            }
            try JSONSerialization.data(withJSONObject: ["input": deviceName(kAudioHardwarePropertyDefaultInputDevice), "output": deviceName(kAudioHardwarePropertyDefaultOutputDevice)], options: .prettyPrinted)
                .write(to: output.appendingPathComponent("devices.json"), options: .atomic)
            if nearEnd {
                try await phase(enabled: false, filename: "near-baseline.caf", externalPlayback: false, instruction: "第一轮：普通采集，请朗读")
                try await phase(enabled: true, filename: "near-processed.caf", externalPlayback: false, instruction: "第二轮：开启回声消除，请朗读")
                try await phase(enabled: true, filename: "doubletalk-processed.caf", externalPlayback: true, instruction: "第三轮：同时外放，请继续朗读")
            } else {
                for enabled in [false, true] { try await phase(enabled: enabled) }
            }
            label.stringValue = "测试已完成。结果仅保存在本机临时目录。"
            try JSONSerialization.data(withJSONObject: ["state": "completed", "phases": results], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("result.json"), options: .atomic)
        } catch {
            engine?.stop(); engine = nil
            label.stringValue = "测试未完成：\(error.localizedDescription)"
            try? JSONSerialization.data(withJSONObject: ["state": "failed", "error": error.localizedDescription, "phases": results], options: .prettyPrinted)
                .write(to: output.appendingPathComponent("result.json"), options: .atomic)
        }
        if CommandLine.arguments.contains("--exit-after-test") { NSApp.terminate(nil) }
    }

    func phase(enabled: Bool, filename requestedName: String? = nil, externalPlayback: Bool = true, instruction: String? = nil) async throws {
        let engine = AVAudioEngine(); self.engine = engine
        let input = engine.inputNode
        _ = engine.outputNode // Materialize both I/O nodes before replacing the hardware unit.
        try input.setVoiceProcessingEnabled(enabled)
        if enabled {
            input.isVoiceProcessingAGCEnabled = false
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        // Never adopt the underlying aggregate device's multi-channel hardware format.
        // Voice I/O's client microphone and playback buses must both be mono / 48 kHz.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let filename = requestedName ?? (enabled ? "processed.caf" : "baseline.caf")
        let writer = try ProbeWriter(url: output.appendingPathComponent(filename), format: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in writer.write(buffer) }
        // Keep the voice-processing output active with silence; never monitor the microphone.
        engine.connect(input, to: engine.mainMixerNode, format: format)
        // VoiceProcessingIO requires matching client-side I/O channel counts and rates.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        changed = false
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.changed = true }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            engine.stop(); input.removeTap(onBus: 0); self.engine = nil
        }
        engine.prepare(); try engine.start()
        let phrase = "我是本机测试人员，今天下午三点检查服务器，验收编号七三九二。"
        if let instruction {
            for remaining in (1...3).reversed() {
                label.stringValue = "\(instruction)（\(remaining) 秒后开始）\n\n请在开始后反复朗读：\n\(phrase)"
                try await Task.sleep(for: .seconds(1))
            }
            label.stringValue = "\(instruction)（正在录音，约 15 秒）\n\n请反复朗读：\n\(phrase)"
        } else {
            label.stringValue = enabled ? "第二轮：系统回声消除已开启。请保持安静，正在播放相同测试语音。" : "第一轮：普通麦克风采集。请保持安静，正在播放测试语音。"
        }
        let started = Date()
        if instruction == nil { try await Task.sleep(for: .seconds(2)) }
        let playback = Process()
        playback.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        playback.arguments = [directory.appendingPathComponent("reference.aiff").path]
        if externalPlayback { activePlayback = playback; try playback.run() }
        else { try await Task.sleep(for: .seconds(13)) }
        defer { if playback.isRunning { playback.terminate() }; activePlayback = nil }
        while playback.isRunning {
            try await Task.sleep(for: .milliseconds(200))
            if Date().timeIntervalSince(started) > 60 { throw NSError(domain: "AECProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "播放超时"] ) }
        }
        if externalPlayback, playback.terminationStatus != 0 { throw NSError(domain: "AECProbe", code: 4) }
        try await Task.sleep(for: .seconds(1))
        engine.stop()
        let writeResult = writer.finish()
        results.append(["voiceProcessing": input.isVoiceProcessingEnabled, "file": filename,
                        "sampleRate": format.sampleRate, "channels": format.channelCount,
                        "elapsed": Date().timeIntervalSince(started), "frames": writeResult.0,
                        "writeError": writeResult.1 ?? "", "configurationChanged": changed])
        if let error = writeResult.1 { throw NSError(domain: "AECProbe", code: 5, userInfo: [NSLocalizedDescriptionKey: error]) }
        guard writeResult.0 > 0, !changed else { throw NSError(domain: "AECProbe", code: 6, userInfo: [NSLocalizedDescriptionKey: "音频配置变化或未收到音频，本轮无效"] ) }
    }
}

final class ProbeWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: Int64 = 0
    private var failure: String?
    init(url: URL, format: AVAudioFormat) throws {
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }
    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        do {
            guard buffer.format.channelCount == 1 else {
                failure = "Unexpected multichannel hardware input; capture invalid"
                return
            }
            try file?.write(from: buffer); frames += Int64(buffer.frameLength)
        }
        catch { failure = error.localizedDescription }
    }
    func finish() -> (Int64, String?) {
        lock.lock(); defer { lock.unlock() }; file = nil
        return (frames, failure)
    }
}

@main struct AECProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ProbeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
