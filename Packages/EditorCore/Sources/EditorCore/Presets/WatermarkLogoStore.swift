import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Imported watermark logos, stored by content hash in a `SyncedFolder` like LUTs,
/// so a recipe can refer to one (`WatermarkLogo`) and every device draws the same file.
///
/// Two formats are stored: PDF, drawn as vectors at whatever size an export needs,
/// and PNG for bitmaps (PNG, JPEG, HEIC, TIFF…), keeping transparency. SVG has no
/// decoder in ImageIO or UIKit, so the app converts it to PDF before importing
/// (`importLogo(pdf:)`); see "Watermark logos" in docs/DESIGN.md.
public final class WatermarkLogoStore: Sendable {
    public let folder: SyncedFolder
    private let renders = Mutex<[(key: RenderKey, image: CGImage)]>([])

    /// Bitmaps larger than this on their long side are scaled down on import:
    /// still sharp as a watermark on a 100 MP export, and quick to send to a phone.
    public static let maxBitmapEdge = 4096
    /// Files larger than this aren't accepted.
    public static let maxFileBytes = 20_000_000

    public enum ImportError: LocalizedError {
        case unreadable, tooLarge
        public var errorDescription: String? {
            switch self {
            case .unreadable: "The file isn't an image or PDF this device can read."
            case .tooLarge: "The file is larger than 20 MB."
            }
        }
    }

    public init(directory: URL) {
        folder = SyncedFolder(directory: directory)
    }

    public static func defaultDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "Watermarks", directoryHint: .isDirectory)
    }

    // MARK: Import

    /// Imports a bitmap (anything ImageIO reads) or a PDF (its first page).
    public func importLogo(from url: URL) throws -> WatermarkLogo {
        let data = try Data(contentsOf: url)
        let name = url.deletingPathExtension().lastPathComponent
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true || data.starts(with: Data("%PDF".utf8)) {
            return try importLogo(pdf: data, name: name)
        }
        return try importLogo(bitmap: data, name: name)
    }

    /// Stores a PDF as is, after checking it has a drawable first page.
    public func importLogo(pdf data: Data, name: String) throws -> WatermarkLogo {
        guard data.count <= Self.maxFileBytes else { throw ImportError.tooLarge }
        guard Self.pdfPage(data).map({ !Self.pageBox($0).isEmpty }) == true else { throw ImportError.unreadable }
        return try store(data, name: name, format: "pdf")
    }

    /// Stores a bitmap as PNG, scaled down to `maxBitmapEdge` if larger.
    public func importLogo(bitmap data: Data, name: String) throws -> WatermarkLogo {
        guard data.count <= Self.maxFileBytes else { throw ImportError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Self.maxBitmapEdge,
              ] as CFDictionary),
              let png = Self.png(image)
        else { throw ImportError.unreadable }
        return try store(png, name: name, format: "png")
    }

    private func store(_ data: Data, name: String, format: String) throws -> WatermarkLogo {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let logo = WatermarkLogo(hash: hash, name: name.isEmpty ? "Logo" : name, format: format)
        if folder.read(logo.fileName) == nil { try folder.write(data, to: logo.fileName) }
        return logo
    }

    /// The stored file, e.g. to send with a render on another device.
    public func data(for logo: WatermarkLogo) -> Data? {
        folder.read(logo.fileName)
    }

    /// Stores a logo another device sent, if its content matches its hash.
    public func add(_ data: Data, for logo: WatermarkLogo) {
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == logo.hash else { return }
        if folder.read(logo.fileName) == nil { try? folder.write(data, to: logo.fileName) }
    }

    // MARK: Drawing

    /// The logo's width / height, or nil if its file is missing or unreadable.
    public func aspectRatio(of logo: WatermarkLogo) -> Double? {
        guard let data = data(for: logo) else { return nil }
        return Self.aspectRatio(data: data, format: logo.format)
    }

    /// The logo drawn `size` pixels large (its aspect ratio, from `aspectRatio(of:)`),
    /// on transparency. A PDF is drawn as vectors at that size; a bitmap is resampled.
    /// The last few renders are cached, since slider drags rebuild the graph every frame.
    public func image(for logo: WatermarkLogo, size: CGSize) -> CGImage? {
        let key = RenderKey(hash: logo.hash, width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        guard key.width > 0, key.height > 0, key.width <= 16_384, key.height <= 16_384 else { return nil }
        if let hit = renders.withLock({ $0.first { $0.key == key }?.image }) { return hit }
        guard let data = data(for: logo), let image = Self.render(data: data, format: logo.format, width: key.width, height: key.height) else { return nil }
        renders.withLock { entries in
            entries.insert((key, image), at: 0)
            if entries.count > 6 { entries.removeLast() }
        }
        return image
    }

    private struct RenderKey: Hashable {
        var hash: String
        var width: Int
        var height: Int
    }

    static func aspectRatio(data: Data, format: String) -> Double? {
        let size: CGSize
        if format == "pdf" {
            guard let page = pdfPage(data) else { return nil }
            size = pageBox(page).size
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Double,
                  let height = properties[kCGImagePropertyPixelHeight] as? Double
            else { return nil }
            size = CGSize(width: width, height: height)
        }
        guard size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }

    static func render(data: Data, format: String, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: RenderContext.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        if format == "pdf" {
            guard let page = pdfPage(data) else { return nil }
            let box = pageBox(page)
            context.scaleBy(x: target.width / box.width, y: target.height / box.height)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            context.draw(image, in: target)
        }
        return context.makeImage()
    }

    private static func pdfPage(_ data: Data) -> CGPDFPage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGPDFDocument(provider)?.page(at: 1)
    }

    /// The visible part of a page: its crop box, ignoring rotation (logos aren't rotated pages).
    private static func pageBox(_ page: CGPDFPage) -> CGRect {
        page.getBoxRect(.cropBox).standardized
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
