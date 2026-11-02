import Foundation
import Darwin

@main struct RecordingLibrarySmoke {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("recording-library-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let folder = root.appendingPathComponent("2026-10-23_14-00-00-ABCDEF")
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        func json(_ name: String, _ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: folder.appendingPathComponent(name))
        }
        try json("meeting.json", ["state": "recording", "duration": 123, "fragments": []])
        var entry = try RecordingEntry.read(folder)
        precondition(entry.needsAttention && entry.status.contains("中断"))
        try json("meeting.json", ["state": "completed", "duration": 123, "fragments": []])
        try RecordingLibrary.writeNote(folder: folder, title: "项目周会", state: "draft")
        entry = try RecordingEntry.read(folder)
        precondition(entry.title == "项目周会" && entry.status == "草稿待保存")
        try Data([1]).write(to: folder.appendingPathComponent("meeting.m4a"))
        try json("export.json", ["file": "meeting.m4a", "title": "项目周会"])
        entry = try RecordingEntry.read(folder)
        precondition(entry.needsAttention) // Existing output cannot hide a draft.
        try RecordingLibrary.writeNote(folder: folder, title: "项目周会", state: "saved")
        entry = try RecordingEntry.read(folder)
        precondition(!entry.needsAttention && entry.audio != nil && entry.status == "已保存")
        try json("export.json", ["file": "meeting.m4a", "title": "项目周会", "subtitle_error": "字幕损坏"])
        entry = try RecordingEntry.read(folder)
        precondition(!entry.needsAttention && entry.subtitleFailed && entry.status.contains("音频已保存"))
        try json("export.json", ["file": "meeting.m4a", "title": "项目周会", "warnings": ["字幕识别未完整结束"]])
        entry = try RecordingEntry.read(folder)
        precondition(entry.subtitleFailed)
        try RecordingLibrary.writeNote(folder: folder, title: "改名", state: "saved")
        entry = try RecordingEntry.read(folder)
        precondition(entry.needsAttention)
        try RecordingLibrary.writeNote(folder: folder, title: "项目周会", state: "failed")
        entry = try RecordingEntry.read(folder)
        precondition(entry.status == "保存失败")
        try RecordingLibrary.writeNote(folder: folder, title: "项目周会", state: "saved")
        try manager.removeItem(at: folder.appendingPathComponent("recording-note.json"))
        try manager.moveItem(at: folder.appendingPathComponent("meeting.m4a"), to: folder.appendingPathComponent("历史会议.m4a"))
        try json("export.json", ["file": "meeting.m4a"])
        entry = try RecordingEntry.read(folder)
        precondition(!entry.needsAttention && entry.title == "历史会议" && entry.audio?.lastPathComponent == "历史会议.m4a")
        try Data([2]).write(to: folder.appendingPathComponent("第二个成品.m4a"))
        entry = try RecordingEntry.read(folder)
        precondition(entry.needsAttention && entry.audio == nil) // Multiple candidates must not be guessed.
        try manager.removeItem(at: folder.appendingPathComponent("第二个成品.m4a"))
        try RecordingLibrary.writeNote(folder: folder, title: "新名称", state: "draft")
        entry = try RecordingEntry.read(folder)
        precondition(entry.needsAttention && entry.title == "新名称") // Reconciliation cannot hide explicit drafts.
        try manager.removeItem(at: folder.appendingPathComponent("recording-note.json"))
        try json("meeting.json", ["state": "interrupted", "duration": 123, "fragments": []])
        entry = try RecordingEntry.read(folder)
        precondition(entry.needsAttention && entry.audio == nil)
        try json("meeting.json", ["state": "completed", "duration": 123, "fragments": []])
        try manager.removeItem(at: folder.appendingPathComponent("export.json"))
        entry = try RecordingEntry.read(folder)
        precondition(entry.needsAttention && entry.audio == nil) // A loose M4A alone is not proof of export.
        try manager.moveItem(at: folder.appendingPathComponent("历史会议.m4a"), to: folder.appendingPathComponent("meeting.m4a"))
        try RecordingLibrary.writeNote(folder: folder, title: "项目周会", state: "saved")
        try json("export.json", ["file": "../meeting.m4a", "title": "项目周会"])
        entry = try RecordingEntry.read(folder)
        precondition(entry.audio == nil && entry.needsAttention)
        precondition(RecordingLibrary.entries(roots: [root, root]).count == 1)
        for name in ["capture.lock", "export.lock"] {
            let fd = Darwin.open(folder.appendingPathComponent(name).path, O_CREAT | O_RDWR, 0o600)
            precondition(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
            var invoked = false
            do {
                try RecordingLibrary.withExclusiveAccess(folder) { invoked = true }
                preconditionFailure("Must reject occupied session")
            } catch { precondition(!invoked) }
            flock(fd, LOCK_UN); Darwin.close(fd)
        }
        try RecordingLibrary.withExclusiveAccess(folder) {}
        try RecordingLibrary.withExclusiveAccess(folder) {} // Locks released after success and failure.
        let link = root.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: folder)
        do { _ = try RecordingEntry.read(link); preconditionFailure("Reject symlink session") } catch {}
        try json("meeting.json", ["state": "completed"])
        precondition(RecordingLibrary.entries(roots: [root]).isEmpty)
        print("PASS: recovery, draft persistence, saved audio/subtitle failures, rename, stale outputs, discovery, lock exclusion and invalid folders")
    }
}
