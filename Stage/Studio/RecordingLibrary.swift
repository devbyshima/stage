import Foundation
import UniformTypeIdentifiers

/// Where recordings wait to be edited: Stage's own folder, not the user's.
/// The Studio exports the finished video wherever they choose.
enum RecordingLibrary {
    static let folder = URL.applicationSupportDirectory
        .appending(path: "Stage/Recordings", directoryHint: .isDirectory)

    /// The newest recordings first.
    static func recent(limit: Int = 10) -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentTypeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .movie) == true }
            .map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
