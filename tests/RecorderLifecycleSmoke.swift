import AppKit
import Foundation

@main struct RecorderLifecycleSmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-journey-" + UUID().uuidString)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let suite = "local.infra.meeting-recorder.lifecycle-test." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let recorder = Recorder(preferences: preferences)
        var prompts = 0
        var choice: NSApplication.ModalResponse = .alertSecondButtonReturn
        recorder.presentAlert = { _ in prompts += 1; return choice }
        func fixture(_ name: String, saved: Bool) throws -> RecordingEntry {
            let folder = root.appendingPathComponent(name)
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            let manifest: [String: Any] = ["state": "completed", "duration": 77, "fragments": []]
            try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("meeting.json"))
            try RecordingLibrary.writeNote(folder: folder, title: name, state: saved ? "saved" : "draft")
            if saved {
                try Data([1]).write(to: folder.appendingPathComponent("meeting.m4a"))
                try JSONSerialization.data(withJSONObject: ["file": "meeting.m4a", "title": name]).write(to: folder.appendingPathComponent("export.json"))
            }
            return try RecordingEntry.read(folder)
        }
        let draft = try fixture("草稿", saved: false)
        let saved = try fixture("已保存", saved: true)
        let canLeaveEmpty = await recorder.prepareToLeave("新建录音")
        precondition(canLeaveEmpty && prompts == 0)
        await recorder.openEntry(draft)
        recorder.titleChanged() // SwiftUI's deferred onChange after loading must not dirty a saved session.
        await recorder.newRecording()
        precondition(recorder.folder == draft.folder && recorder.meetingTitle == "草稿" && prompts == 1)
        await recorder.openEntry(saved)
        precondition(recorder.folder == draft.folder && prompts == 2) // Cancel switching keeps the draft.
        choice = .alertThirdButtonReturn
        await recorder.newRecording()
        precondition(recorder.folder == nil && recorder.meetingTitle.isEmpty && recorder.elapsed == 0)
        let retained = try RecordingEntry.read(draft.folder)
        precondition(retained.needsAttention && retained.title == "草稿")
        await recorder.openEntry(saved)
        recorder.titleChanged()
        let before = prompts
        let canLeaveSaved = await recorder.prepareToLeave("退出应用")
        precondition(canLeaveSaved && prompts == before)
        recorder.meetingTitle = "改过的名称"; recorder.titleChanged()
        choice = .alertSecondButtonReturn
        let cancelClose = await recorder.prepareToLeave("退出应用")
        precondition(!cancelClose && recorder.folder == saved.folder)
        choice = .alertFirstButtonReturn
        let failedSave = await recorder.prepareToLeave("新建录音") // No export script in test bundle.
        precondition(!failedSave && recorder.folder == saved.folder && recorder.lifecycle == "保存失败")
        choice = .alertThirdButtonReturn
        await recorder.newRecording()
        let renamed = try RecordingEntry.read(saved.folder)
        precondition(recorder.folder == nil && renamed.title == "改过的名称" && renamed.needsAttention)
        await recorder.openEntry(draft)
        recorder.busy = true
        let blocked = await recorder.prepareToLeave("退出应用")
        precondition(!blocked && recorder.folder == draft.folder)
        recorder.busy = false
        choice = .alertFirstButtonReturn // Cancel deletion is first button.
        await recorder.removeRecording()
        precondition(manager.fileExists(atPath: draft.folder.path) && recorder.folder == draft.folder)
        choice = .alertSecondButtonReturn
        recorder.moveToTrash = { _ in throw libraryError("测试移动失败") }
        await recorder.removeRecording()
        precondition(recorder.folder == draft.folder && manager.fileExists(atPath: draft.folder.path))
        recorder.moveToTrash = { source in try manager.moveItem(at: source, to: root.appendingPathComponent("test-trash")) }
        await recorder.removeRecording()
        precondition(recorder.folder == nil && !manager.fileExists(atPath: draft.folder.path))
        precondition(manager.fileExists(atPath: root.appendingPathComponent("test-trash/meeting.json").path))
        precondition(!recorder.echoCancellationEnabled)
        recorder.echoCancellationEnabled = true
        precondition(Recorder(preferences: preferences).echoCancellationEnabled)
        recorder.echoCancellationEnabled = false
        precondition(!Recorder(preferences: preferences).echoCancellationEnabled)
        recorder.echoCancellationEnabled = true
        let restored = Recorder(preferences: preferences)
        precondition(restored.echoCancellationEnabled && !restored.echoCancellationActive)
        restored.microphone = "specific-device"
        precondition(restored.microphone == "specific-device" && restored.echoCancellationEnabled)
        print("PASS: new/open/quit decisions, cancellation preserves context, retained drafts, clean saved sessions, renamed metadata, save failure blocks leaving, busy guard, cancel deletion, failed move preserves context and successful move clears session")
    }
}
