import Foundation

public enum RecipeCodecError: Error, Equatable, LocalizedError {
    case newerSchema(Int)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .newerSchema(let version): "This edit was made by a newer version of the app (recipe v\(version))."
        case .malformed(let reason): "The edit data is damaged: \(reason)"
        }
    }
}

/// Encodes recipes as compact JSON and decodes any schema version we have ever written.
///
/// Old versions are upgraded by `migrations`: each step takes the JSON object of
/// version N and returns version N+1. Never edit a shipped step; add a new one.
public enum RecipeCodec {
    /// Migration steps keyed by the version they upgrade *from*.
    static let migrations: [Int: @Sendable ([String: Any]) throws -> [String: Any]] = [:]

    public static func encode(_ recipe: Recipe) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(recipe)
    }

    public static func decode(_ data: Data) throws -> Recipe {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RecipeCodecError.malformed("not a JSON object")
        }
        guard var version = object["schemaVersion"] as? Int else {
            throw RecipeCodecError.malformed("missing schemaVersion")
        }
        guard version <= Recipe.currentSchemaVersion else { throw RecipeCodecError.newerSchema(version) }

        while version < Recipe.currentSchemaVersion {
            guard let step = migrations[version] else {
                throw RecipeCodecError.malformed("no migration from v\(version)")
            }
            object = try step(object)
            version += 1
            object["schemaVersion"] = version
        }

        let upgraded = try JSONSerialization.data(withJSONObject: object)
        do {
            return try JSONDecoder().decode(Recipe.self, from: upgraded)
        } catch {
            throw RecipeCodecError.malformed(String(describing: error))
        }
    }
}
