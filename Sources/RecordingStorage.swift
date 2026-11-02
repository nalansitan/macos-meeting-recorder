import Foundation

enum RecordingStorage {
    static func prepareRoot(parent: URL) throws {
        let manager = FileManager.default
        func error(_ message: String) -> NSError {
            NSError(domain: "MeetingRecorder.Storage", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message])
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw error("保存目录不存在或磁盘尚未连接，请重新选择保存位置。")
        }
        let root = parent.appendingPathComponent("会议录音", isDirectory: true)
        if !manager.fileExists(atPath: root.path) {
            do {
                try manager.createDirectory(at: root, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            } catch {
                // Another window/process may have created the directory meanwhile.
                guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw error
                }
            }
        }
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw error("保存位置中已有名为“会议录音”的文件，无法作为录音文件夹；请选择其他位置。")
        }
        guard manager.isWritableFile(atPath: root.path) else {
            throw error("没有写入保存目录的权限，请重新选择保存位置。")
        }
    }
}
