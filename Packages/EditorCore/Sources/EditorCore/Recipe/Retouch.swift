import Foundation

/// One retouch: an area painted on the original image and how to fill it.
///
/// Like masks, spots are recipes, not pixels. Heal and clone copy from a source
/// area; Remove fills the area with an inpainting model, recomputed (and cached)
/// on each device.
public struct RetouchSpot: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        /// AI fill from the surroundings (LaMa).
        case remove
        /// Copy texture from the source, matched to the target's tone and color.
        case heal
        /// Copy the source exactly.
        case clone

        public var id: String { rawValue }
        public var displayName: String { rawValue.capitalized }

        public var systemImage: String {
            switch self {
            case .remove: "wand.and.stars"
            case .heal: "bandage"
            case .clone: "square.on.square.dashed"
            }
        }

        public var needsSource: Bool { self != .remove }
    }

    public var id: UUID
    /// Application order; later spots work on the result of earlier ones.
    public var order: Double
    public var kind: Kind
    /// The painted area, in normalized coordinates of the original image.
    public var strokes: [BrushStroke]
    /// Where heal and clone copy from: source = target + offset (normalized).
    public var sourceOffset: NormalizedPoint?
    public var opacity: Double
    /// How Remove fills the area. Part of the spot, so a fill is recomputed when it changes.
    public var engine: RemoveEngine
    /// Which of the diffusion fills to use ("Try another" counts up); seeds the noise.
    public var variation: Int

    public init(
        id: UUID = UUID(), order: Double, kind: Kind, strokes: [BrushStroke], sourceOffset: NormalizedPoint? = nil,
        opacity: Double = 1, engine: RemoveEngine = .standard, variation: Int = 0
    ) {
        self.id = id
        self.order = order
        self.kind = kind
        self.strokes = strokes
        self.sourceOffset = sourceOffset
        self.opacity = opacity
        self.engine = engine
        self.variation = variation
    }

    private enum CodingKeys: String, CodingKey {
        case id, order, kind, strokes, sourceOffset, opacity, engine, variation
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(order, forKey: .order)
        try container.encode(kind, forKey: .kind)
        try container.encode(strokes, forKey: .strokes)
        try container.encodeIfPresent(sourceOffset, forKey: .sourceOffset)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(engine, forKey: .engine)
        // Only when set, so existing spots keep their chain keys and cached fills.
        if variation != 0 { try container.encode(variation, forKey: .variation) }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        order = try container.decode(Double.self, forKey: .order)
        kind = try container.decode(Kind.self, forKey: .kind)
        strokes = try container.decode([BrushStroke].self, forKey: .strokes)
        sourceOffset = try container.decodeIfPresent(NormalizedPoint.self, forKey: .sourceOffset)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        engine = try container.decodeIfPresent(RemoveEngine.self, forKey: .engine) ?? .standard
        variation = try container.decodeIfPresent(Int.self, forKey: .variation) ?? 0
    }

    public var key: ParamKey { ParamKey.retouch(id) }

    /// The painted area's bounding box, including the brush radius (normalized).
    public var bounds: NormalizedRect {
        var minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0
        for stroke in strokes {
            for point in stroke.points {
                minX = min(minX, point.x - stroke.radius)
                minY = min(minY, point.y - stroke.radius)
                maxX = max(maxX, point.x + stroke.radius)
                maxY = max(maxY, point.y + stroke.radius)
            }
        }
        guard maxX > minX, maxY > minY else { return NormalizedRect(x: 0, y: 0, width: 0, height: 0) }
        return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// How Remove fills an area.
public enum RemoveEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    /// LaMa at up to 1024 px, cut from the full-resolution original: native
    /// resolution for anything up to about 400 px across.
    case standard
    /// LaMa at 512 px from the preview, as before: quicker, softer on big areas.
    case fast
    /// Stable Diffusion inpainting: invents new content for big areas. Slow.
    case diffusion

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: "LaMa · full resolution"
        case .fast: "LaMa · fast"
        case .diffusion: "LaMa + diffusion"
        }
    }

    public var detail: String {
        switch self {
        case .standard: "Best for most removals. Up to 1024 px, from the full-resolution original."
        case .fast: "Quicker and softer: 512 px from the preview."
        case .diffusion: "Most realistic: LaMa removes it, then diffusion makes the area look like a photo. About 30 s."
        }
    }
}

extension ParamKey {
    public static let retouchPrefix = "retouch."

    public static func retouch(_ id: UUID) -> ParamKey { ParamKey(retouchPrefix + id.uuidString) }

    public var isRetouch: Bool { rawValue.hasPrefix(ParamKey.retouchPrefix) }
}

extension Recipe {
    /// Retouch spots in application order.
    public var retouches: [RetouchSpot] {
        params.compactMap { key, value -> RetouchSpot? in
            guard key.isRetouch, case .retouch(let spot) = value else { return nil }
            return spot
        }
        .sorted { ($0.order, $0.id.uuidString) < ($1.order, $1.id.uuidString) }
    }

    public mutating func setRetouch(_ spot: RetouchSpot, at stamp: HLCStamp) {
        set(spot.key, .retouch(spot), at: stamp)
    }

    public mutating func removeRetouch(_ id: UUID, at stamp: HLCStamp) {
        set(.retouch(id), nil, at: stamp)
    }

    public var nextRetouchOrder: Double { (retouches.map(\.order).max() ?? 0) + 1 }
}
