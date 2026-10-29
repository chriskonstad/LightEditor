import CryptoKit
import Foundation

/// A stable identifier for a photo: the SHA-256 of the original file's bytes.
/// It works offline and before upload, on every device.
public struct PhotoID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static func of(fileAt url: URL) throws -> PhotoID {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return PhotoID(rawValue: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    public static func of(data: Data) -> PhotoID {
        PhotoID(rawValue: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    /// Used before the hash is known.
    public static let pending = PhotoID(rawValue: "")

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue.isEmpty ? "pending" : String(rawValue.prefix(12)) }
}

/// The RAW decoder version a recipe was made with. Pinned so that renders match
/// across devices and OS updates.
public struct DecoderPin: Codable, Sendable, Hashable {
    /// A `CIRAWDecoderVersion` raw value such as "9", or "none" for non-RAW files.
    public var version: String

    public init(version: String) { self.version = version }

    public static let raw9 = DecoderPin(version: "9")
    public static let none = DecoderPin(version: "none")
}

/// A non-destructive edit: a flat map of parameter to value.
///
/// Rendering is a pure function of (original, recipe). An absent key means the
/// default. Every change records a per-parameter stamp, including resets, so that a
/// later merge can tell a reset from a value that was never touched.
public struct Recipe: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var photoID: PhotoID
    public var decoder: DecoderPin
    public private(set) var params: [ParamKey: ParamValue]
    public private(set) var stamps: [ParamKey: HLCStamp]

    public init(photoID: PhotoID = .pending, decoder: DecoderPin = .raw9) {
        schemaVersion = Recipe.currentSchemaVersion
        self.photoID = photoID
        self.decoder = decoder
        params = [:]
        stamps = [:]
    }

    public subscript(key: ParamKey) -> ParamValue? { params[key] }

    /// The explicit scalar value for `key`, or nil when it's at its default.
    public func scalar(_ key: ParamKey) -> Double? { params[key]?.scalarValue }

    /// The effective scalar value for `key`, falling back to the photo's default.
    public func scalar(_ key: ParamKey, defaults: PhotoDefaults) -> Double {
        scalar(key) ?? defaults.value(for: key)
    }

    public var isIdentity: Bool { params.isEmpty }

    /// Sets a value, or resets it to its default when `value` is nil. Scalars equal to
    /// their fixed default are stored as absent.
    public mutating func set(_ key: ParamKey, _ value: ParamValue?, at stamp: HLCStamp) {
        var value = value
        if let spec = ParamCatalog.spec(for: key) {
            if case .scalar(let number)? = value {
                let clamped = spec.clamp(number)
                if let fixed = spec.fixedDefault, abs(clamped - fixed) < 1e-9 {
                    value = nil
                } else {
                    value = .scalar(clamped)
                }
            }
            if case .crop(let geometry)? = value, geometry.isIdentity, geometry.aspect == nil { value = nil }
            if case .point(let x, let y)? = value, abs(x) < 1e-9, abs(y) < 1e-9 { value = nil }
            if case .curve(let points)? = value, points.isIdentityCurve { value = nil }
        }
        guard params[key] != value || stamps[key] == nil else { return }
        params[key] = value
        stamps[key] = stamp
    }

    public mutating func setScalar(_ key: ParamKey, _ value: Double, at stamp: HLCStamp) {
        set(key, .scalar(value), at: stamp)
    }

    /// Resets every parameter to its default, keeping stamps as reset markers.
    public mutating func resetAll(at stamp: HLCStamp) {
        for key in params.keys { set(key, nil, at: stamp) }
    }

    /// The parameters in the given paste groups.
    public func params(in groups: Set<PasteGroup>) -> [ParamKey: ParamValue] {
        params.filter { key, _ in
            guard let group = ParamCatalog.spec(for: key)?.group else { return false }
            return groups.contains(group)
        }
    }

    /// The parameters that affect the RAW decode, used as the decode cache key.
    public var rawStage: RawStageParams {
        RawStageParams(
            decoderVersion: decoder.version,
            noiseReduction: scalar(.noiseReduction),
            colorNoise: scalar(.colorNoise),
            sharpness: scalar(.sharpness),
            detail: scalar(.detail),
            lensCorrection: scalar(.lensCorrection),
            moire: scalar(.moire)
        )
    }

    /// The decode that AI masks and fills are computed from. Only lens correction
    /// matters there, since it moves pixels.
    public var analysisStage: RawStageParams { RawStageParams(lensCorrection: rawStage.lensCorrection) }

    /// Caches AI masks and fills per photo and per lens-correction setting.
    public func analysisKey(for photoKey: String) -> String {
        rawStage.lensCorrection == 0 ? photoKey + "|no-lens-correction" : photoKey
    }

    /// Whether any of the grouped parameters differ from the default.
    public func hasEdits(in group: PasteGroup) -> Bool {
        params.keys.contains { ParamCatalog.spec(for: $0)?.group == group }
    }
}

/// RAW-stage parameters. Changing any of these re-decodes the RAW.
public struct RawStageParams: Hashable, Sendable, Codable {
    public var decoderVersion: String
    public var noiseReduction: Double?
    public var colorNoise: Double?
    public var sharpness: Double?
    public var detail: Double?
    /// nil keeps the decoder's default (on).
    public var lensCorrection: Double?
    public var moire: Double?

    public init(
        decoderVersion: String = DecoderPin.raw9.version, noiseReduction: Double? = nil, colorNoise: Double? = nil,
        sharpness: Double? = nil, detail: Double? = nil, lensCorrection: Double? = nil, moire: Double? = nil
    ) {
        self.decoderVersion = decoderVersion
        self.noiseReduction = noiseReduction
        self.colorNoise = colorNoise
        self.sharpness = sharpness
        self.detail = detail
        self.lensCorrection = lensCorrection
        self.moire = moire
    }

    public var cacheKey: String {
        func fmt(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "d" }
        var key = "v\(decoderVersion)-nr\(fmt(noiseReduction))-cn\(fmt(colorNoise))-sh\(fmt(sharpness))-dt\(fmt(detail))"
        // Only when set, so existing cache entries keep their keys.
        if let lensCorrection { key += "-lc\(fmt(lensCorrection))" }
        if let moire { key += "-mo\(fmt(moire))" }
        return key
    }
}

extension Array where Element == CurvePoint {
    /// True for an empty curve or a straight line from (0,0) to (1,1).
    public var isIdentityCurve: Bool {
        allSatisfy { abs($0.x - $0.y) < 1e-6 }
    }
}
