import Foundation
import ImageIO

/// Originals copied out of the photo library for editing. Photos keeps the real
/// copy, so this is a cache: files are reused while they can be read, fetched
/// again when they can't, and trimmed to a size limit.
///
/// Each original is fetched at most once at a time: a second request for one
/// that's still downloading (say, the photo reopened while its first download
/// runs on) waits for that download instead of starting another into the same
/// file. Downloads write to a file of their own and are moved into place when
/// complete, so a cached original is never half-written.
public actor OriginalsCache {
    public nonisolated let directory: URL
    private var running: [String: Task<URL, any Error>] = [:]

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The cached original called `name`. `fetch` writes it to the URL it's given
    /// (which doesn't exist yet), and runs only when the file is missing or can't
    /// be read as an image.
    public func file(named name: String, fetch: @escaping @Sendable (URL) async throws -> Void) async throws -> URL {
        if let task = running[name] { return try await task.value }
        let url = directory.appending(path: name)
        if Self.isReadableImage(url) { return url }
        let directory = directory
        let task = Task {
            try? FileManager.default.removeItem(at: url)
            let partial = directory.appending(path: ".\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: partial) }
            try await fetch(partial)
            try FileManager.default.moveItem(at: partial, to: url)
            return url
        }
        running[name] = task
        defer { running[name] = nil }
        return try await task.value
    }

    /// Whether `url` is a complete image file: present, not empty, and with
    /// readable image properties. A truncated TIFF fails this (its directory of
    /// images is usually at the end), as does a file this app can't read at all.
    nonisolated static func isReadableImage(_ url: URL) -> Bool {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0) > 0
    }

    /// Deletes the least recently used originals until the rest fit in `limit`
    /// bytes, and any downloads a previous launch left unfinished.
    public nonisolated func trim(limit: Int) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentAccessDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var entries: [(URL, Int, Date)] = []
        for url in files {
            if url.pathExtension == "partial" {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            entries.append((url, values.fileSize ?? 0, values.contentAccessDate ?? .distantPast))
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > limit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}
