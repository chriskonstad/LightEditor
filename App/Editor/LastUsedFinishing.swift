import EditorCore
import Foundation

/// The border and the watermark last used on any photo, so the Finish tab can
/// offer them again with one tap ("Last used"). Kept on this device, in user
/// defaults; a logo watermark refers to its file in the synced logo store.
enum LastUsedFinishing {
    enum Part: String, CaseIterable {
        case border, watermark

        var keys: [ParamKey] {
            switch self {
            case .border: Finishing.frameKeys
            case .watermark: Finishing.watermarkKeys
            }
        }

        var label: String {
            switch self {
            case .border: "Last used border"
            case .watermark: "Last used watermark"
            }
        }

        private var defaultsKey: String { "lastUsedFinishing.\(rawValue)" }

        /// This part's settings in `recipe`, or nil when it isn't in use there.
        func values(in recipe: Recipe) -> [ParamKey: ParamValue]? {
            switch self {
            case .border: guard Finishing.hasFrame(recipe) else { return nil }
            case .watermark: guard Finishing.watermark(recipe) != nil else { return nil }
            }
            return Dictionary(uniqueKeysWithValues: keys.compactMap { key in recipe[key].map { (key, $0) } })
        }

        var saved: [ParamKey: ParamValue]? {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
            return try? JSONDecoder().decode([ParamKey: ParamValue].self, from: data)
        }

        func clear() { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        func save(_ values: [ParamKey: ParamValue]) {
            guard let data = try? JSONEncoder().encode(values) else { return }
            UserDefaults.standard.set(data, forKey: defaultsKey)
            // Written now: the app may be quit (or killed) right after a change.
            UserDefaults.standard.synchronize()
        }

        /// The saved settings as changes to a recipe: every key of the part, nil
        /// where the saved settings leave it at its default.
        var changes: [ParamKey: ParamValue?]? {
            guard let saved else { return nil }
            return Dictionary(uniqueKeysWithValues: keys.map { ($0, saved[$0]) })
        }
    }

    /// Remembers each part that's in use in `recipe`. A part that's off is left
    /// alone, so opening a photo without a border doesn't forget the last one.
    static func remember(_ recipe: Recipe) {
        for part in Part.allCases {
            if let values = part.values(in: recipe), values != part.saved { part.save(values) }
        }
    }
}
