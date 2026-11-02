import Foundation

@main struct RecordingStorageSmoke {
    static func main() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("meeting-storage-test-" + UUID().uuidString)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        for name in ["Movies", "自定义目录"] {
            let parent = base.appendingPathComponent(name)
            try manager.createDirectory(at: parent, withIntermediateDirectories: false)
            try RecordingStorage.prepareRoot(parent: parent)
            let existing = parent.appendingPathComponent("会议录音/已有录音.txt")
            try Data("保留已有录音".utf8).write(to: existing)
            for _ in 0..<3 { try RecordingStorage.prepareRoot(parent: parent) }
            let contents = try String(contentsOf: existing, encoding: .utf8)
            precondition(contents == "保留已有录音")
        }
        let conflict = base.appendingPathComponent("冲突目录")
        try manager.createDirectory(at: conflict, withIntermediateDirectories: false)
        let file = conflict.appendingPathComponent("会议录音")
        try Data("不要覆盖".utf8).write(to: file)
        do {
            try RecordingStorage.prepareRoot(parent: conflict)
            preconditionFailure("Must reject a same-name regular file")
        } catch {
            precondition(error.localizedDescription.contains("已有名为"))
        }
        let contents = try String(contentsOf: file, encoding: .utf8)
        precondition(contents == "不要覆盖")
        do {
            try RecordingStorage.prepareRoot(parent: base.appendingPathComponent("不存在"))
            preconditionFailure("Must reject a missing parent")
        } catch {
            precondition(error.localizedDescription.contains("保存目录不存在"))
        }
        print("PASS: repeated default/custom directory preparation, preserved recordings, file conflict and missing parent")
    }
}
