import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EditorCore

/// The kinds of TIFF people bring in from Files: 8- and 16-bit, compressed or not, with alpha.
enum TIFFKind: String, CaseIterable, Sendable {
    case rgb8, rgb16, lzw8, lzw16, alpha8

    /// Writes a small gradient TIFF of this kind to `url`.
    func write(to url: URL, size: Int = 96) throws {
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: CGFloat(size), y: CGFloat(size)),
            "inputColor0": CIColor(red: 0.8, green: 0.3, blue: 0.1), "inputColor1": CIColor(red: 0.1, green: 0.4, blue: 0.9),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let sixteen = self == .rgb16 || self == .lzw16
        let image = try #require(RenderContext.background.createCGImage(
            gradient, from: gradient.extent, format: sixteen ? .RGBA16 : .RGBA8, colorSpace: RenderContext.sRGB
        ))
        let opaque = self != .alpha8
        let drawn: CGImage
        if opaque {
            // Drop alpha, the way most cameras and scanners write TIFFs.
            let context = try #require(CGContext(
                data: nil, width: size, height: size, bitsPerComponent: sixteen ? 16 : 8, bytesPerRow: 0,
                space: RenderContext.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | (sixteen ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            drawn = try #require(context.makeImage())
        } else {
            drawn = image
        }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        let compression = (self == .lzw8 || self == .lzw16) ? 5 : 1
        CGImageDestinationAddImage(destination, drawn, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: compression],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }
}

@Suite struct OriginalsCacheTests {
    func temporary() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "originals-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    func visibleFiles(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    @Test func reusesACachedOriginal() async throws {
        let cache = OriginalsCache(directory: temporary())
        let fetches = Counter()
        for _ in 0..<3 {
            let url = try await cache.file(named: "A_L0_001-IMG_4506.TIF") { destination in
                fetches.increment()
                try TIFFKind.rgb8.write(to: destination)
            }
            #expect(OriginalsCache.isReadableImage(url))
        }
        #expect(fetches.value == 1)
    }

    /// Reopening a photo while its first download is still running used to start
    /// a second download into the same file, which could leave it truncated.
    @Test func fetchesEachOriginalOnceAtATime() async throws {
        let directory = temporary()
        let cache = OriginalsCache(directory: directory)
        let fetches = Counter()
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await cache.file(named: "B_L0_001-IMG_4506.TIF") { destination in
                        fetches.increment()
                        try await Task.sleep(for: .milliseconds(200))
                        try TIFFKind.lzw16.write(to: destination)
                    }
                }
            }
            return try await group.reduce(into: Set<URL>()) { $0.insert($1) }
        }
        #expect(fetches.value == 1)
        #expect(urls.count == 1)
        #expect(OriginalsCache.isReadableImage(try #require(urls.first)))
        #expect(visibleFiles(directory) == ["B_L0_001-IMG_4506.TIF"], "no download files left behind")
    }

    /// Issue #3: a TIFF that opened once couldn't be read again. A truncated TIFF
    /// loses the directory at its end, so nothing can read it; the cache fetches
    /// such a file again instead of handing it to the decoder forever.
    @Test(arguments: TIFFKind.allCases)
    func refetchesATruncatedOriginal(kind: TIFFKind) async throws {
        let cache = OriginalsCache(directory: temporary())
        let fetches = Counter()
        let fetch: @Sendable (URL) async throws -> Void = { destination in
            fetches.increment()
            try kind.write(to: destination)
        }
        let url = try await cache.file(named: "C-IMG.TIF", fetch: fetch)
        let data = try Data(contentsOf: url)
        try data.prefix(data.count / 2).write(to: url)
        #expect(!OriginalsCache.isReadableImage(url))
        await #expect(throws: (any Error).self, "the decoder can't read it, which is what the issue showed") {
            _ = try await RawDecoder(cache: DecodeCache(directory: nil)).info(for: PhotoSource(url: url))
        }

        let again = try await cache.file(named: "C-IMG.TIF", fetch: fetch)
        #expect(fetches.value == 2)
        #expect(OriginalsCache.isReadableImage(again))
        _ = try await RawDecoder(cache: DecodeCache(directory: nil)).info(for: PhotoSource(url: again))
    }

    @Test func refetchesAnEmptyOrMissingFile() async throws {
        let directory = temporary()
        let cache = OriginalsCache(directory: directory)
        let fetches = Counter()
        let fetch: @Sendable (URL) async throws -> Void = { destination in
            fetches.increment()
            try TIFFKind.rgb8.write(to: destination)
        }
        let url = try await cache.file(named: "D.TIF", fetch: fetch)
        try Data().write(to: url)
        _ = try await cache.file(named: "D.TIF", fetch: fetch)
        try FileManager.default.removeItem(at: url)
        _ = try await cache.file(named: "D.TIF", fetch: fetch)
        #expect(fetches.value == 3)
    }

    @Test func aFailedDownloadLeavesNothingBehind() async throws {
        struct Offline: Error {}
        let directory = temporary()
        let cache = OriginalsCache(directory: directory)
        await #expect(throws: Offline.self) {
            _ = try await cache.file(named: "E.TIF") { destination in
                try Data("half a file".utf8).write(to: destination)
                throw Offline()
            }
        }
        #expect(visibleFiles(directory).isEmpty)
        let url = try await cache.file(named: "E.TIF") { try TIFFKind.rgb8.write(to: $0) }
        #expect(OriginalsCache.isReadableImage(url))
    }

    @Test func trimDropsUnfinishedDownloadsAndTheOldest() throws {
        let directory = temporary()
        let cache = OriginalsCache(directory: directory)
        try Data(repeating: 1, count: 1000).write(to: directory.appending(path: "old.ARW"))
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: directory.appending(path: "old.ARW").path)
        try (directory.appending(path: "old.ARW") as NSURL).setResourceValue(Date(timeIntervalSince1970: 0), forKey: .contentAccessDateKey)
        try Data(repeating: 2, count: 1000).write(to: directory.appending(path: "new.ARW"))
        try Data(repeating: 3, count: 10).write(to: directory.appending(path: ".1234.partial"))
        try Data(repeating: 4, count: 10).write(to: directory.appending(path: "IMG.TIF.partial"))
        cache.trim(limit: 1500)
        #expect(visibleFiles(directory) == ["new.ARW"])
    }
}

/// Open, edit, save and reopen TIFFs end to end through a folder library: the
/// reopen must find the original and the saved edit, as on the first open.
@Suite struct TIFFReopenTests {
    @Test(arguments: TIFFKind.allCases)
    func reopensAfterSaving(kind: TIFFKind) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "tiff-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try kind.write(to: directory.appending(path: "IMG_4506.TIF"))
        let library = FolderLibrary(directory: directory)
        let assets = await library.assets(in: .recents)
        #expect(assets.count == 1)
        let asset = assets[0]

        for round in 0..<2 {
            // A fresh decoder each time, so nothing is served from memory.
            let decoder = RawDecoder(cache: DecodeCache(directory: nil))
            let session = try await library.beginEditing(asset) { _ in }
            let info = try await decoder.info(for: session.original)
            #expect(!info.isRAW)
            #expect(info.nativeSize == CGSize(width: 96, height: 96))
            let decoded = try await decoder.decode(session.original, rawStage: RawStageParams(decoderVersion: info.decoderVersion), longEdge: 2560)
            #expect(decoded.image.extent.size == CGSize(width: 96, height: 96))

            var recipe = Recipe(decoder: DecoderPin(version: info.decoderVersion))
            if round == 1 {
                guard case .ours(let stored) = session.stored else {
                    Issue.record("the saved edit is missing on reopen")
                    return
                }
                #expect(stored.scalar(.exposure) == 0.5)
                recipe = stored
            }
            recipe.setScalar(.exposure, 0.5, at: testClock.now())
            let rendered = try await Exporter.render(source: session.original, recipe: recipe, luts: nil, options: ExportOptions(format: .jpeg), decoder: decoder)
            try await library.save(session, recipe: recipe, rendered: rendered, format: .jpeg)
        }
    }
}
