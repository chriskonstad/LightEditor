import CoreImage
import CoreVideo
import CryptoKit
import Foundation

/// A decoded, scene-linear RGBA16F intermediate held in an IOSurface-backed pixel
/// buffer, so Core Image samples it on the GPU without a copy.
public struct DecodedImage: @unchecked Sendable {
    public let image: CIImage
    public let pixelBuffer: CVPixelBuffer
    public let info: SourceInfo

    public var size: CGSize { image.extent.size }
    var byteCount: Int { CVPixelBufferGetDataSize(pixelBuffer) }

    init(pixelBuffer: CVPixelBuffer, info: SourceInfo) {
        self.pixelBuffer = pixelBuffer
        self.info = info
        self.image = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: RenderContext.linearP3])
    }

    /// A smaller copy for previews: screen-sized grading is several times cheaper
    /// than grading the 2560 px decode and scaling it down. Renders on the
    /// calling thread; call it off the main thread.
    public func downscaled(toLongEdge longEdge: Int) throws -> DecodedImage {
        let scale = min(1, Double(longEdge) / max(size.width, size.height))
        guard scale < 1 else { return self }
        let small = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        let extent = small.extent.integral
        guard let buffer = PixelBuffers.make(width: Int(extent.width), height: Int(extent.height)) else { throw DecodeError.renderFailed }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = RenderContext.linearP3
        let origin = small.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        _ = try RenderContext.shared.startTask(toRender: origin, from: CGRect(origin: .zero, size: extent.size), to: destination, at: .zero).waitUntilCompleted()
        return DecodedImage(pixelBuffer: buffer, info: info)
    }

    private struct Header: Codable {
        var width: Int
        var height: Int
        var bytesPerRow: Int
        var info: SourceInfo
    }

    /// The exact half-float pixels plus info, for the disk cache and for sending
    /// to another device: a 4-byte header length, a JSON header, then the rows.
    public func serialized() -> Data? {
        let buffer = pixelBuffer
        let header = Header(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), info: info)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys  // The same bytes for the same image.
        guard let headerData = try? encoder.encode(header) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var data = Data()
        var headerLength = UInt32(headerData.count)
        data.append(Data(bytes: &headerLength, count: 4))
        data.append(headerData)
        data.append(Data(bytes: base, count: header.bytesPerRow * header.height))
        return data
    }

    public init?(serialized data: Data) {
        guard data.count > 4 else { return nil }
        let headerLength = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let start = data.startIndex
        guard data.count > 4 + headerLength,
              let header = try? JSONDecoder().decode(Header.self, from: data.subdata(in: (start + 4)..<(start + 4 + headerLength))),
              data.count >= 4 + headerLength + header.bytesPerRow * header.height,
              let buffer = PixelBuffers.make(width: header.width, height: header.height)
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let destinationStride = CVPixelBufferGetBytesPerRow(buffer)
        let rowBytes = min(destinationStride, header.bytesPerRow)
        data.withUnsafeBytes { raw in
            let pixels = raw.baseAddress!.advanced(by: 4 + headerLength)
            for row in 0..<header.height {
                memcpy(base.advanced(by: row * destinationStride), pixels.advanced(by: row * header.bytesPerRow), rowBytes)
            }
        }
        self.init(pixelBuffer: buffer, info: header.info)
    }
}

/// Memory + disk LRU cache of decoded intermediates.
///
/// Keyed by photo + RAW-stage parameters + size, so grading changes never miss and
/// only Detail changes re-decode. The disk tier stores raw half-float pixels, which
/// load in milliseconds compared with seconds for a RAW 9 decode.
public actor DecodeCache {
    public struct Key: Hashable, Sendable {
        public var photoKey: String
        public var rawStage: RawStageParams
        public var longEdge: Int

        /// Bump when decoding changes, so stale entries on disk are never reused.
        static let formatVersion = 2

        var fileName: String {
            let digest = SHA256.hash(data: Data("v\(Self.formatVersion)|\(photoKey)|\(rawStage.cacheKey)|\(longEdge)".utf8))
            return digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".rgbah"
        }
    }

    private var memory: [Key: DecodedImage] = [:]
    private var order: [Key] = []
    private let memoryLimit: Int
    private let diskLimit: Int
    private let directory: URL?

    public init(memoryLimit: Int? = nil, diskLimit: Int = 2 << 30, directory: URL? = DecodeCache.defaultDirectory) {
        let physical = Int(ProcessInfo.processInfo.physicalMemory)
        self.memoryLimit = memoryLimit ?? max(physical / 24, 128 << 20)
        self.diskLimit = diskLimit
        self.directory = directory
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "DecodeCache", directoryHint: .isDirectory)
    }

    public func image(for key: Key) -> DecodedImage? {
        if let hit = memory[key] {
            touch(key)
            return hit
        }
        guard let loaded = loadFromDisk(key) else { return nil }
        insertInMemory(loaded, for: key)
        return loaded
    }

    public func insert(_ image: DecodedImage, for key: Key) {
        insertInMemory(image, for: key)
        writeToDisk(image, key: key)
    }

    public func removeAll() {
        memory.removeAll()
        order.removeAll()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Drops in-memory entries, e.g. on a memory warning. The disk tier is kept.
    public func trimMemory() {
        memory.removeAll()
        order.removeAll()
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func insertInMemory(_ image: DecodedImage, for key: Key) {
        memory[key] = image
        touch(key)
        var total = memory.values.reduce(0) { $0 + $1.byteCount }
        while total > memoryLimit, order.count > 1, let oldest = order.first {
            order.removeFirst()
            if let removed = memory.removeValue(forKey: oldest) { total -= removed.byteCount }
        }
    }

    // MARK: Disk tier

    private func writeToDisk(_ image: DecodedImage, key: Key) {
        guard let directory, let data = image.serialized() else { return }
        try? data.write(to: directory.appending(path: key.fileName))
        evictDiskIfNeeded()
    }

    private func loadFromDisk(_ key: Key) -> DecodedImage? {
        guard let directory else { return nil }
        let url = directory.appending(path: key.fileName)
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), let image = DecodedImage(serialized: data) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return image
    }

    private func evictDiskIfNeeded() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return }
        var entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > diskLimit else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > diskLimit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}

enum PixelBuffers {
    static func make(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_64RGBAHalf, attributes as CFDictionary, &buffer)
        return buffer
    }
}
