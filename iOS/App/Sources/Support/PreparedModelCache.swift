import Foundation

/// Core ML's prepared copies of the on-device models. Core ML writes one
/// bundle per model into `Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache/<OS build>/`
/// on the first load for this device and OS, and reads it on later loads.
/// There is no API for this cache; the session log reports what is on disk
/// next to each load time, so a slow load can be told apart: the bundles
/// are gone (iOS cleared the cache), or they are there and the time goes
/// somewhere else.
enum PreparedModelCache {
    /// Walks the cache off the calling actor, so a note from the main actor
    /// does not block it on the file system.
    static func describe() async -> String {
        await Task.detached(priority: .utility) { description }.value
    }

    private static var description: String {
        guard let bundleID = Bundle.main.bundleIdentifier else { return "prepared models: unknown" }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
        guard let builds = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return "prepared models: no cache directory"
        }
        var count = 0
        var bytes: Int64 = 0
        var newest: Date?
        for build in builds {
            let bundles = (try? FileManager.default.contentsOfDirectory(at: build, includingPropertiesForKeys: nil)) ?? []
            for bundle in bundles where bundle.pathExtension == "bundle" {
                count += 1
                let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
                let files = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: Array(keys))
                while let file = files?.nextObject() as? URL {
                    guard let values = try? file.resourceValues(forKeys: keys) else { continue }
                    bytes += Int64(values.fileSize ?? 0)
                    if let date = values.contentModificationDate, date > newest ?? .distantPast { newest = date }
                }
            }
        }
        guard count > 0, let newest else { return "prepared models: none" }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return String(format: "prepared models: %d, %@, newest %@ ago", count, size, Self.age(newest))
    }

    private static func age(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 90 { return String(format: "%.0fs", seconds) }
        if seconds < 5400 { return String(format: "%.0fm", seconds / 60) }
        return String(format: "%.1fh", seconds / 3600)
    }
}
