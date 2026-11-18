import Foundation
import Synchronization

/// A folder of small files that lives in the app's iCloud Drive container when
/// iCloud is available, so every device signed in to the same Apple ID sees the
/// same presets and LUTs, and in Application Support when it isn't.
///
/// Reads and writes go through `NSFileCoordinator`, as iCloud Drive requires.
/// Files another device added that aren't downloaded yet are skipped (and their
/// download started); `UbiquitousFolderWatcher` reports when they arrive.
public final class SyncedFolder: Sendable {
    private let current: Mutex<URL>

    public init(directory: URL) {
        current = Mutex(directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var url: URL { current.withLock { $0 } }

    /// The files with `pathExtension`, by name, that are on this device.
    public func files(withExtension pathExtension: String) -> [String] {
        let directory = url
        let keys: [URLResourceKey] = [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        var names: [String] = []
        for item in items {
            var name = item.lastPathComponent
            // An older-style placeholder for a file not downloaded yet: ".name.ext.icloud".
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
                if (name as NSString).pathExtension == pathExtension {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: directory.appending(path: name))
                }
                continue
            }
            guard item.pathExtension == pathExtension else { continue }
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus, status != .current {
                try? FileManager.default.startDownloadingUbiquitousItem(at: item)
                if status == .notDownloaded { continue }
            }
            names.append(name)
        }
        return names
    }

    /// The file's contents, or nil if it's missing or not downloaded yet (its
    /// download starts, so a read never waits on the network).
    public func read(_ name: String) -> Data? {
        let file = url.appending(path: name)
        let values = try? file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            return nil
        }
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &error) { url in
            data = try? Data(contentsOf: url)
        }
        return data
    }

    public func write(_ data: Data, to name: String) throws {
        var error: NSError?
        var thrown: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: url.appending(path: name), options: .forReplacing, error: &error) { url in
            do { try data.write(to: url, options: .atomic) } catch { thrown = error }
        }
        if let failure = error ?? thrown { throw failure }
    }

    public func delete(_ name: String) throws {
        var error: NSError?
        var thrown: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: url.appending(path: name), options: .forDeleting, error: &error) { url in
            do { try FileManager.default.removeItem(at: url) } catch { thrown = error }
        }
        if let failure = error ?? thrown { throw failure }
    }

    /// Moves to `directory`, taking along any files it doesn't already have.
    /// Used once iCloud is available, to bring presets made before it was.
    public func move(to directory: URL) {
        let old = url
        guard old.standardizedFileURL != directory.standardizedFileURL else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? []
        for item in items where !item.lastPathComponent.hasPrefix(".") {
            let destination = directory.appending(path: item.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: item)
                continue
            }
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: item, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &error) { from, to in
                try? FileManager.default.moveItem(at: from, to: to)
            }
        }
        current.withLock { $0 = directory }
    }
}

/// Where synced app data lives: the iCloud Drive container, or nil without iCloud.
public enum UbiquitousStorage {
    /// The app's iCloud Drive container. Slow the first time (it may create the
    /// container), so never call it on the main thread.
    public static func container() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)
    }
}

/// Watches the iCloud Drive container for files that change on other devices,
/// and calls `onChange` (on the main actor) when any do, at most every half second.
@MainActor
public final class UbiquitousFolderWatcher {
    private let query = NSMetadataQuery()
    private let onChange: @MainActor () -> Void
    private var observers: [Task<Void, Never>] = []
    private var pending: Task<Void, Never>?

    public init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    self?.changed()
                }
            })
        }
        query.start()
    }

    isolated deinit {
        query.stop()
        observers.forEach { $0.cancel() }
    }

    private func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }
}
