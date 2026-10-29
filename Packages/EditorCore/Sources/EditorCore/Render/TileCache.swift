import CoreImage
import Foundation
import Synchronization

/// Full-resolution pixels for zoomed-in previews, decoded in tiles as needed.
///
/// Grading a RAW straight from `CIRAWFilter` re-runs the decode for every frame
/// and blocks on a slow first decode. Instead, the preview asks for the area it
/// needs (`request`); tiles decode one at a time in the background, nearest the
/// middle of that area first, and `image(over:)` puts the decoded ones over a
/// stand-in (the 2560 px decode, enlarged) so the photo shows at once and
/// sharpens as tiles arrive. Least recently used tiles are dropped beyond `limit`.
public final class TileCache: @unchecked Sendable {
    public static let tileSize = 1024

    /// The source's extent: the full-resolution image, or a downscaled level of it.
    public let extent: CGRect
    /// The source's long edge as a fraction of the original's.
    public let level: Double
    private let source: CIImage
    private let limit: Int

    private struct Tile {
        var image: CIImage
        var lastUsed: UInt64
    }
    private struct State {
        var tiles: [TileKey: Tile] = [:]
        var wanted: [TileKey] = []
        var decoding: TileKey?
        var working = false
        var clock: UInt64 = 0
        var cancelled = false
    }
    private let state = Mutex(State())
    /// Called (on any thread) when a tile arrives.
    private let onTile: @Sendable () -> Void

    struct TileKey: Hashable {
        var column: Int
        var row: Int
    }

    /// `source` is a lazy RAW image (e.g. from `RawDecoder.lazyImage`); rendering
    /// a tile of it runs the decode for that area only.
    public init(source: CIImage, level: Double, limit: Int = 16, onTile: @escaping @Sendable () -> Void) {
        self.source = source
        self.extent = source.extent
        self.level = level
        self.limit = limit
        self.onTile = onTile
    }

    /// Tiles still to decode for the last request.
    public var pendingCount: Int { state.withLock { $0.wanted.count + ($0.decoding == nil ? 0 : 1) } }

    public func cancelAll() {
        state.withLock {
            $0.cancelled = true
            $0.wanted.removeAll()
        }
    }

    /// Frees memory, e.g. on a memory warning. Tiles decode again when needed.
    public func trim() {
        state.withLock { $0.tiles.removeAll() }
    }

    func rect(for key: TileKey) -> CGRect {
        let size = CGFloat(Self.tileSize)
        return CGRect(x: extent.minX + CGFloat(key.column) * size, y: extent.minY + CGFloat(key.row) * size, width: size, height: size)
            .intersection(extent)
    }

    func keys(covering rect: CGRect) -> [TileKey] {
        let area = rect.intersection(extent)
        guard !area.isNull, !area.isEmpty else { return [] }
        let size = CGFloat(Self.tileSize)
        let columns = Int(floor((area.minX - extent.minX) / size))...Int(floor((area.maxX - extent.minX - 0.001) / size))
        let rows = Int(floor((area.minY - extent.minY) / size))...Int(floor((area.maxY - extent.minY - 0.001) / size))
        return columns.flatMap { column in rows.map { TileKey(column: column, row: $0) } }
    }

    /// The decoded tiles over `fallback`, which is enlarged to the full extent.
    public func image(over fallback: CIImage) -> CIImage {
        let fallbackExtent = fallback.extent
        var image = fallback
            .transformed(by: CGAffineTransform(translationX: -fallbackExtent.minX, y: -fallbackExtent.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width / fallbackExtent.width, y: extent.height / fallbackExtent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        let tiles = state.withLock { $0.tiles.values.map(\.image) }
        for tile in tiles { image = tile.composited(over: image) }
        return image.cropped(to: extent)
    }

    /// Asks for the tiles covering `rect` (full-resolution coordinates); the ones
    /// not cached yet decode in the background, nearest its middle first. A new
    /// request replaces the previous one, so panning away drops stale work. Only
    /// the `limit` tiles nearest the middle are kept, so a request never evicts
    /// its own tiles; the rest of the area shows the fallback.
    public func request(_ area: CGRect) {
        let center = CGPoint(x: area.midX, y: area.midY)
        let start = state.withLock { state -> Bool in
            state.cancelled = false
            state.clock += 1
            let keys = keys(covering: area).sorted {
                let a = self.rect(for: $0), b = self.rect(for: $1)
                return hypot(a.midX - center.x, a.midY - center.y) < hypot(b.midX - center.x, b.midY - center.y)
            }.prefix(limit)
            for key in keys where state.tiles[key] != nil { state.tiles[key]?.lastUsed = state.clock }
            state.wanted = keys.filter { state.tiles[$0] == nil && $0 != state.decoding }
            guard !state.wanted.isEmpty, !state.working else { return false }
            state.working = true
            return true
        }
        if start { Task.detached(priority: .userInitiated) { [self] in await work() } }
    }

    private func work() async {
        while true {
            guard let key = state.withLock({ state -> TileKey? in
                guard !state.cancelled, !state.wanted.isEmpty else {
                    state.working = false
                    return nil
                }
                let key = state.wanted.removeFirst()
                state.decoding = key
                return key
            }) else { return }
            do {
                let tile = try await decode(key)
                state.withLock { state in
                    state.decoding = nil
                    state.clock += 1
                    state.tiles[key] = Tile(image: tile, lastUsed: state.clock)
                    // Drop the least recently used beyond the limit.
                    while state.tiles.count > limit, let oldest = state.tiles.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                        state.tiles[oldest] = nil
                    }
                }
                onTile()
            } catch {
                state.withLock {
                    $0.decoding = nil
                    $0.working = false
                }
                return
            }
        }
    }

    private func decode(_ key: TileKey) async throws -> CIImage {
        let rect = rect(for: key)
        let signpostID = Signposts.decode.makeSignpostID()
        let interval = Signposts.decode.beginInterval("Tile", id: signpostID)
        defer { Signposts.decode.endInterval("Tile", interval) }
        guard let buffer = PixelBuffers.make(width: Int(rect.width), height: Int(rect.height)) else { throw DecodeError.renderFailed }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = RenderContext.linearP3
        _ = try RenderContext.shared.startTask(toRender: source, from: rect, to: destination, at: .zero).waitUntilCompleted()
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: RenderContext.linearP3])
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}
