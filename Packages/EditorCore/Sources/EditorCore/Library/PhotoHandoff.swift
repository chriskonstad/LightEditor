import Foundation
import ImageIO

// "Edit in LightEditor" from Apple Photos (docs/spikes/open-from-photos.md).
//
// Photos gives a share extension a rendered copy of the photo, not the library asset,
// so the extension reads what identifies it (the original's filename, the capture
// time and the size) and opens the app with a `lighteditor://edit` URL. The app then
// finds the asset in its own library through `SharedPhotoLookup` and edits the
// original, saving through PhotoKit as usual.

/// What identifies a photo shared from Apple Photos: the original's filename, its
/// capture time from EXIF, and its pixel size.
public struct SharedPhoto: Sendable, Hashable {
    /// The filename without its extension, e.g. "DSCF2030" (Photos names the shared
    /// copy after the original: DSCF2030.RAF is shared as DSCF2030.heic).
    public var name: String?
    /// EXIF DateTimeOriginal as written, "yyyy:MM:dd HH:mm:ss", in the camera's local time.
    public var taken: String?
    /// EXIF OffsetTimeOriginal ("+09:00"), when the camera recorded its time zone.
    public var offset: String?
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(name: String?, taken: String?, offset: String? = nil, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.name = name.map(Self.baseName).flatMap { $0.isEmpty ? nil : $0 }
        self.taken = taken
        self.offset = offset
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Reads a shared image file's name and metadata. `name` overrides the file's own
    /// name, for item providers that suggest one.
    public init?(imageAt url: URL, name: String? = nil) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        // EXIF orientations 5–8 turn the image a quarter, so it displays the other way round.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        self.init(
            name: name ?? url.lastPathComponent,
            taken: exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff[kCGImagePropertyTIFFDateTime] as? String,
            offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String,
            pixelWidth: width,
            pixelHeight: height
        )
    }

    /// "DSCF2030.RAF" → "dscf2030", for comparing filenames.
    static func baseName(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension.lowercased()
    }

    // MARK: Capture time

    /// The capture time read as if it were UTC, plus the camera's offset when known.
    private var clock: (utc: Date, offset: TimeInterval?)? {
        guard let taken else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = formatter.date(from: String(taken.prefix(19))) else { return nil }
        return (date, offset.flatMap(Self.seconds(fromOffset:)))
    }

    /// "+09:00" → 32400.
    static func seconds(fromOffset text: String) -> TimeInterval? {
        let parts = text.dropFirst().split(separator: ":")
        guard let sign = text.first, sign == "+" || sign == "-", parts.count == 2,
              let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        return TimeInterval((sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }

    /// Photos' creation dates keep sub-second precision; EXIF times here don't.
    static let timeTolerance: TimeInterval = 1.5
    /// Time zones run from UTC−12 to UTC+14.
    private static let zoneSpan: ClosedRange<TimeInterval> = -14 * 3600 ... 12 * 3600

    /// The creation dates the library photo could have. Without a recorded offset, the
    /// library stored the camera's local time in some time zone, so any zone counts.
    public var searchRange: ClosedRange<Date>? {
        guard let clock else { return nil }
        if let offset = clock.offset {
            let instant = clock.utc.addingTimeInterval(-offset)
            return instant.addingTimeInterval(-Self.timeTolerance) ... instant.addingTimeInterval(Self.timeTolerance)
        }
        return clock.utc.addingTimeInterval(Self.zoneSpan.lowerBound - Self.timeTolerance)
            ... clock.utc.addingTimeInterval(Self.zoneSpan.upperBound + Self.timeTolerance)
    }

    /// Whether a library photo created at `date` could be this one: the same instant
    /// when the offset is known, else the same local time in a real time zone (whole
    /// quarter hours away from UTC).
    public func couldBeTaken(at date: Date?) -> Bool {
        guard let date, let clock, let range = searchRange, range.contains(date) else { return false }
        if clock.offset != nil { return true }
        let quarter: TimeInterval = 15 * 60
        let remainder = date.timeIntervalSince(clock.utc).truncatingRemainder(dividingBy: quarter)
        let distance = min(abs(remainder), quarter - abs(remainder))
        return distance <= Self.timeTolerance
    }
}

// MARK: - Hand-off URL

/// The URL the share extension opens: `lighteditor://edit?name=…&taken=…&offset=…&size=WxH`.
public struct PhotoHandoff: Sendable, Hashable {
    public static let scheme = "lighteditor"
    public static let host = "edit"
    public var photo: SharedPhoto

    public init(photo: SharedPhoto) { self.photo = photo }

    public var url: URL {
        var items: [(String, String)] = []
        if let name = photo.name { items.append(("name", name)) }
        if let taken = photo.taken { items.append(("taken", taken)) }
        if let offset = photo.offset { items.append(("offset", offset)) }
        if photo.pixelWidth > 0, photo.pixelHeight > 0 { items.append(("size", "\(photo.pixelWidth)x\(photo.pixelHeight)")) }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        // Encoded by hand: URLComponents leaves "+" alone, and readers decode it as a space.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        components.percentEncodedQuery = items.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return components.url!
    }

    /// Reads a hand-off URL; nil for any other URL, or one with nothing to match on.
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme, components.host?.lowercased() == Self.host else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] { values[item.name] = item.value }
        let size = values["size"]?.split(separator: "x").compactMap { Int($0) } ?? []
        let photo = SharedPhoto(
            name: values["name"],
            taken: values["taken"],
            offset: values["offset"],
            pixelWidth: size.count == 2 ? size[0] : 0,
            pixelHeight: size.count == 2 ? size[1] : 0
        )
        guard photo.searchRange != nil else { return nil }
        self.photo = photo
    }
}

// MARK: - Finding the library photo

/// A library photo that could be the shared one, with its resources' filenames
/// (a RAW+JPEG pair has both).
public struct HandoffCandidate: Sendable {
    public var asset: PhotoAsset
    public var filenames: [String]

    public init(asset: PhotoAsset, filenames: [String]) {
        self.asset = asset
        self.filenames = filenames
    }
}

/// A library that can find the photo a shared copy came from.
public protocol SharedPhotoLookup: Sendable {
    /// Photos whose creation date passes `photo.couldBeTaken(at:)`, with their filenames.
    func candidates(for photo: SharedPhoto) async -> [HandoffCandidate]
}

extension SharedPhotoLookup {
    /// The library photos the shared one most likely is, best first. More than one
    /// means identical copies (the same file imported twice).
    public func assets(matching photo: SharedPhoto) async -> [PhotoAsset] {
        guard photo.searchRange != nil else { return [] }
        return SharedPhotoMatcher.rank(photo, among: await candidates(for: photo))
    }
}

public enum SharedPhotoMatcher {
    /// Keeps the candidates taken at the shared photo's time that agree best on
    /// filename and size. A matching time alone isn't enough when there's a name or a
    /// size to check, so a burst or a friend's photo from the same second isn't opened.
    public static func rank(_ photo: SharedPhoto, among candidates: [HandoffCandidate]) -> [PhotoAsset] {
        let scored = candidates
            .filter { photo.couldBeTaken(at: $0.asset.creationDate) }
            .map { ($0.asset, score(photo, $0)) }
        guard let best = scored.map(\.1).max() else { return [] }
        let hasEvidence = photo.name != nil || photo.pixelWidth > 0
        if hasEvidence, best == 0 { return [] }
        return scored.filter { $0.1 == best }.map(\.0)
    }

    /// Filename 2, size 1: the name survives crops, the size survives renamed copies.
    static func score(_ photo: SharedPhoto, _ candidate: HandoffCandidate) -> Int {
        var score = 0
        if let name = photo.name, candidate.filenames.contains(where: { SharedPhoto.baseName($0) == name }) {
            score += 2
        }
        let shared = [photo.pixelWidth, photo.pixelHeight].sorted()
        let library = [candidate.asset.pixelWidth, candidate.asset.pixelHeight].sorted()
        if shared[0] > 0, shared == library { score += 1 }
        return score
    }
}
