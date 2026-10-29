import CryptoKit
import Foundation

/// Unsaved edits, written to disk after every change so a crash or a killed app
/// doesn't lose them. Edits reach the library only when the photo is closed or
/// the app goes to the background; saving clears the draft.
public struct RecipeDrafts: Sendable {
    public static let shared = RecipeDrafts(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Drafts", directoryHint: .isDirectory)
    )

    let directory: URL?

    public init(directory: URL?) {
        self.directory = directory
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    private func url(for assetID: String) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(assetID.utf8))
        return directory.appending(path: digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".json")
    }

    public func save(_ recipe: Recipe, for assetID: String) {
        guard let url = url(for: assetID), let data = try? RecipeCodec.encode(recipe) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func load(for assetID: String) -> Recipe? {
        guard let url = url(for: assetID), let data = try? Data(contentsOf: url) else { return nil }
        return try? RecipeCodec.decode(data)
    }

    /// Removes the draft if it holds `saved` (a newer draft stays).
    public func clear(for assetID: String, ifMatching saved: Recipe? = nil) {
        guard let url = url(for: assetID) else { return }
        if let saved, let draft = load(for: assetID), draft.params != saved.params { return }
        try? FileManager.default.removeItem(at: url)
    }
}
