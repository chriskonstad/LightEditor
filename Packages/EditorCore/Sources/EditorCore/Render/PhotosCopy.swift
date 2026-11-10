import Foundation

/// The size and quality of the image saved to the library with an edit.
///
/// Photos keeps the original next to the edit, so this image is only what Photos,
/// other apps and sharing show; the original still holds every pixel, and
/// LightEditor re-renders from it. A smaller copy saves iCloud storage: a 61 MP
/// HEIC at quality 0.9 runs 5–17 MB, at 24 MP and 0.8 about 1–3.5 MB.
///
/// A photo can set its own (`ParamKey.photosMaxMegapixels`, `.photosQuality`, the
/// "Saved image size" paste group); otherwise this device's default from Settings
/// applies, on the device that renders the save.
public struct PhotosCopy: Sendable, Hashable, Codable {
    /// The largest size in megapixels; 0 is full size.
    public var maxMegapixels: Double
    public var quality: Double

    public init(maxMegapixels: Double = 0, quality: Double = PhotosCopy.full.quality) {
        self.maxMegapixels = maxMegapixels
        self.quality = quality
    }

    public static let qualityRange: ClosedRange<Double> = 0.4...1
    /// Full size at quality 0.9, as every save was before this setting existed.
    public static let full = PhotosCopy(maxMegapixels: 0, quality: 0.9)

    /// `UserDefaults` keys for this device's default (written by Settings).
    public static let megapixelsDefaultsKey = "photosCopyMegapixels"
    public static let qualityDefaultsKey = "photosCopyQuality"

    /// This device's default, from Settings.
    public static var deviceDefault: PhotosCopy {
        let defaults = UserDefaults.standard
        return PhotosCopy(
            maxMegapixels: defaults.object(forKey: megapixelsDefaultsKey) as? Double ?? full.maxMegapixels,
            quality: defaults.object(forKey: qualityDefaultsKey) as? Double ?? full.quality
        )
    }

    public var isFullSize: Bool { maxMegapixels <= 0 }

    /// Options for the save's render.
    public func exportOptions(format: ExportFormat = .heic) -> ExportOptions {
        ExportOptions(format: format, maxMegapixels: isFullSize ? nil : maxMegapixels, quality: quality)
    }

    /// The pixel size of the saved image for a photo whose edit is `full` pixels.
    public func outputSize(full: CGSize) -> CGSize {
        guard !isFullSize, full.width * full.height > maxMegapixels * 1_000_000 else { return full }
        return ExportSizing.size(longEdge: ExportSizing.longEdge(megapixels: maxMegapixels, for: full), full: full)
    }
}

extension Recipe {
    /// The photo's saved image size, falling back to `fallback` for what it doesn't set.
    public func photosCopy(fallback: PhotosCopy = .deviceDefault) -> PhotosCopy {
        PhotosCopy(
            maxMegapixels: scalar(.photosMaxMegapixels) ?? fallback.maxMegapixels,
            quality: scalar(.photosQuality) ?? fallback.quality
        )
    }

    /// Whether the photo sets its own saved image size.
    public var hasOwnPhotosCopy: Bool {
        scalar(.photosMaxMegapixels) != nil || scalar(.photosQuality) != nil
    }
}
