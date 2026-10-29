import Foundation

/// How pasted or bulk values combine with the target's own edits.
public enum PasteMode: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Copy absolute values, as in "make these look the same".
    case set
    /// Add the source's change from its default, e.g. +0.3 EV to everything.
    case adjust

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .set: "Set values"
        case .adjust: "Adjust by (+/−)"
        }
    }
}

/// A copied recipe plus enough context to paste it relative to its source.
public struct RecipeClip: Codable, Sendable, Hashable {
    public var recipe: Recipe
    public var sourceName: String
    public var copiedAt: Date
    /// The source photo's own defaults, so relative pastes know what "unchanged" means.
    public var sourceDefaults: PhotoDefaults

    public init(recipe: Recipe, sourceName: String, copiedAt: Date = Date(), sourceDefaults: PhotoDefaults) {
        self.recipe = recipe
        self.sourceName = sourceName
        self.copiedAt = copiedAt
        self.sourceDefaults = sourceDefaults
    }
}

extension Recipe {
    /// Returns this recipe with the clip's parameters from `groups` pasted on top.
    public func pasting(
        _ clip: RecipeClip,
        groups: Set<PasteGroup>,
        mode: PasteMode,
        targetDefaults: PhotoDefaults,
        stamp: HLCStamp
    ) -> Recipe {
        var result = self
        let keys = ParamCatalog.all.filter { groups.contains($0.group) }
        for spec in keys {
            let key = spec.key
            var source = clip.recipe[key]
            // Auto straighten is found again on the target rather than copied.
            if case .crop(let geometry)? = source { source = .crop(geometry.forPasting) }
            switch mode {
            case .set:
                result.set(key, source, at: stamp)
            case .adjust:
                switch spec.kind {
                case .scalar:
                    guard let sourceValue = source?.scalarValue else { continue }
                    let delta = sourceValue - clip.sourceDefaults.value(for: key)
                    guard abs(delta) > 1e-9 else { continue }
                    let base = result.scalar(key, defaults: targetDefaults)
                    result.setScalar(key, base + delta, at: stamp)
                case .point:
                    guard let (dx, dy) = source?.pointValue else { continue }
                    let (x, y) = result[key]?.pointValue ?? (0, 0)
                    var nx = x + dx, ny = y + dy
                    let length = (nx * nx + ny * ny).squareRoot()
                    if length > 1 { nx /= length; ny /= length }
                    result.set(key, .point(x: nx, y: ny), at: stamp)
                case .curve, .lut, .crop, .mask, .retouch:
                    // These have no meaningful delta; paste them only when the source has one.
                    if let source { result.set(key, source, at: stamp) }
                }
            }
        }
        if groups.contains(.masks) {
            // Set replaces the target's masks; Adjust adds the source's on top.
            if mode == .set {
                for layer in result.masks { result.removeMask(layer.id, at: stamp) }
            }
            for layer in clip.recipe.masks { result.setMask(layer, at: stamp) }
        }
        if groups.contains(.retouch) {
            if mode == .set {
                for spot in result.retouches { result.removeRetouch(spot.id, at: stamp) }
            }
            for spot in clip.recipe.retouches { result.setRetouch(spot, at: stamp) }
        }
        return result
    }

    /// Applies slider values to this recipe in either mode. In `.adjust` mode the
    /// values are deltas.
    public func applying(
        _ values: [ParamKey: Double],
        mode: PasteMode,
        defaults: PhotoDefaults,
        stamp: HLCStamp
    ) -> Recipe {
        var result = self
        for (key, value) in values {
            switch mode {
            case .set: result.setScalar(key, value, at: stamp)
            case .adjust: result.setScalar(key, result.scalar(key, defaults: defaults) + value, at: stamp)
            }
        }
        return result
    }
}
