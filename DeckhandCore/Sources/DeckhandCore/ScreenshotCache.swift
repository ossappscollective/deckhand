import Foundation

/// A temporary folder for the screenshots that are shown as a thumbnail and dragged out of it, rather than saved in the
/// capture folder. Files stay for a few days, because an app a thumbnail was dropped on may read the file later.
public enum ScreenshotCache {
    public static let keepsFor: TimeInterval = 3 * 24 * 3600

    /// The folder, created when missing; files older than `keepsFor` are removed on the way.
    public static func directory(in base: URL = FileManager.default.temporaryDirectory,
                                 now: Date = Date()) -> String {
        let folder = base.appendingPathComponent("Deckhand Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        purge(folder, olderThan: now.addingTimeInterval(-keepsFor))
        return folder.path
    }

    static func purge(_ folder: URL, olderThan cutoff: Date) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantFuture
            if modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}
