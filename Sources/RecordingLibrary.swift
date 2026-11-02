import Foundation
import Darwin

struct RecordingNote: Codable {
    var title: String
    var state: String
}

struct RecordingEntry: Identifiable {
    var id: String { folder.path }
    let folder: URL
    let title: String
    let duration: Double
    let status: String
    let needsAttention: Bool
    let audio: URL?
    let subtitleFailed: Bool

    static func read(_ folder: URL) throws -> RecordingEntry {
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw libraryError("请选择有效的录音文件夹。") }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meeting.json"))) as? [String: Any]
        guard let manifest, manifest["fragments"] is [[String: Any]], let state = manifest["state"] as? String else {
            throw libraryError("此文件夹不是有效的会议录音。")
        }
        let note = (try? Data(contentsOf: folder.appendingPathComponent("recording-note.json"))).flatMap { try? JSONDecoder().decode(RecordingNote.self, from: $0) }
        let report = (try? Data(contentsOf: folder.appendingPathComponent("export.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let exportedTitle = report?["title"] as? String ?? ""
        var audio: URL?
        if let name = report?["file"] as? String, !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { audio = url }
        }
        // Older exports may have been renamed in Finder without updating export.json.
        // Only reconcile an existing export with one unambiguous, nonempty regular M4A.
        if audio == nil, state == "completed",
           let originalName = report?["file"] as? String, !originalName.isEmpty,
           originalName == URL(fileURLWithPath: originalName).lastPathComponent {
            let candidates = try FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
                .filter { url in
                    guard url.pathExtension.lowercased() == "m4a",
                          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
                    return values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? 0) > 0
                }
            if candidates.count == 1 { audio = candidates[0] }
        }
        let title = note?.title ?? (exportedTitle.isEmpty ? audio?.deletingPathExtension().lastPathComponent : exportedTitle) ?? ""
        let displayTitle = title == "meeting" && exportedTitle.isEmpty && note == nil ? "" : title
        let warnings = report?["warnings"] as? [String] ?? []
        let subtitleFailed = report?["subtitle_error"] as? String != nil || warnings.contains { $0.contains("字幕") || $0.contains("SRT 为空") }
        let pending = note?.state == "draft" || note?.state == "failed" || audio == nil || (note != nil && title != exportedTitle)
        let status: String
        if note?.state == "failed" { status = "保存失败" }
        else if pending { status = ["recording", "paused", "interrupted"].contains(state) ? "中断录音 · 待恢复" : "草稿待保存" }
        else { status = subtitleFailed ? "音频已保存 · 字幕异常" : "已保存" }
        let duration = manifest["duration"] as? Double ?? 0
        guard duration.isFinite, duration >= 0, duration < Double(Int.max) else {
            throw libraryError("录音时长记录损坏，请保留原始文件以便恢复。")
        }
        return RecordingEntry(folder: folder, title: displayTitle, duration: duration,
                              status: status, needsAttention: pending, audio: audio, subtitleFailed: subtitleFailed)
    }
}

func libraryError(_ text: String) -> NSError {
    NSError(domain: "MeetingRecorder.Library", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
}

enum RecordingLibrary {
    static func writeNote(folder: URL, title: String, state: String) throws {
        try JSONEncoder().encode(RecordingNote(title: title, state: state))
            .write(to: folder.appendingPathComponent("recording-note.json"), options: .atomic)
    }

    // Hold both locks while moving the entire session, including fragments and subtitles.
    static func withExclusiveAccess<T>(_ folder: URL, action: () throws -> T) throws -> T {
        var descriptors: [Int32] = []
        defer { for fd in descriptors { flock(fd, LOCK_UN); Darwin.close(fd) } }
        for name in ["export.lock", "capture.lock"] {
            let fd = Darwin.open(folder.appendingPathComponent(name).path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else { throw libraryError("无法访问录音，请检查磁盘和文件权限。") }
            descriptors.append(fd)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw libraryError("这场录音正在被录制或导出，请完成后再操作。") }
        }
        return try action()
    }

    static func entries(roots: [URL]) -> [RecordingEntry] {
        var seen = Set<String>()
        return roots.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .compactMap { try? RecordingEntry.read($0) }
            .sorted { $0.folder.lastPathComponent > $1.folder.lastPathComponent }
    }
}
