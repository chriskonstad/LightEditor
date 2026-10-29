import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// The phone's side of remote editing: answers the iPad from this device's
/// library and does the heavy work here (RAW decodes, AI masks, Remove fills,
/// full-size saves, exports and bulk edits). The iPad only grades the decoded
/// image on its own GPU.
public final class RemoteHost: @unchecked Sendable {
    private let library: any PhotoLibrary
    private let decoder: RawDecoder
    private let luts: (any LUTProvider)?
    private let clock: HybridLogicalClock
    private let assets = Mutex<[String: PhotoAsset]>([:])
    private let sessions = Mutex<[String: EditingSession]>([:])
    /// Keeps the app running briefly in the background while work is in flight.
    private let beginActivity: @Sendable (String) -> @Sendable () -> Void

    /// Requests by idempotency key. A retry after a reconnection joins the
    /// original work, or gets its answer if it already finished, so a save or
    /// bulk edit never runs twice and work isn't lost when the link drops.
    private struct Work {
        var task: Task<RemoteResponse, any Error>
        /// Where progress goes: the latest link to ask.
        var progress: @Sendable (Double?, String?) -> Void
        var finishedAt: Date?
    }
    private final class Registry: Sendable {
        let running = Mutex<[String: Work]>([:])
    }
    private let work = Registry()

    public init(
        library: any PhotoLibrary, decoder: RawDecoder = .shared, luts: (any LUTProvider)?, clock: HybridLogicalClock,
        beginActivity: @escaping @Sendable (String) -> @Sendable () -> Void = { _ in {} }
    ) {
        self.library = library
        self.decoder = decoder
        self.luts = luts
        self.clock = clock
        self.beginActivity = beginActivity
    }

    /// Answers `link`'s requests and tells it when the library changes. Call
    /// again with each new link after a reconnection; work in flight carries on.
    public func serve(_ link: PeerLink) {
        link.setHandler { [self] request, key, progress in
            try await answer(request, key: key, progress: progress)
        }
        let stream = library.changes()
        Task { [weak link] in
            for await _ in stream {
                guard let link, !link.isClosed else { return }
                link.send(.libraryChanged)
            }
        }
    }

    /// Runs a request once per key, detached from the link that asked.
    func answer(_ request: RemoteRequest, key: String?, progress: @escaping @Sendable (Double?, String?) -> Void) async throws -> RemoteResponse {
        guard let key else { return try await handle(request, progress: progress) }
        let registry = work
        let task = work.running.withLock { running -> Task<RemoteResponse, any Error> in
            // Forget old finished work.
            let cutoff = Date().addingTimeInterval(-600)
            running = running.filter { $0.value.finishedAt.map { $0 > cutoff } ?? true }
            if var existing = running[key] {
                existing.progress = progress
                running[key] = existing
                return existing.task
            }
            let end = beginActivity("Editing for another device")
            let task = Task<RemoteResponse, any Error> { [self] in
                defer { end() }
                do {
                    let response = try await handle(request) { fraction, detail in
                        registry.running.withLock { $0[key]?.progress }?(fraction, detail)
                    }
                    registry.running.withLock { running in
                        // Big answers (decodes, exports) are cheap to redo; keep only small ones.
                        if case .done = response { running[key]?.finishedAt = Date() } else { running[key] = nil }
                    }
                    return response
                } catch {
                    registry.running.withLock { $0[key] = nil }  // A retry runs it again.
                    throw error
                }
            }
            running[key] = Work(task: task, progress: progress)
            return task
        }
        return try await task.value
    }

    // MARK: Requests

    public func handle(_ request: RemoteRequest, progress: @escaping @Sendable (Double?, String?) -> Void) async throws -> RemoteResponse {
        switch request {
        case .albums:
            return .albums(await library.albums())

        case .assets(let album):
            let list = await library.assets(in: album)
            let all = (0..<list.count).map { list[$0] }
            assets.withLock { known in for asset in all { known[asset.id] = asset } }
            return .assets(all)

        case .thumbnail(let id, let pixels):
            let image = await library.thumbnail(for: try await asset(id), pixelSize: CGSize(width: pixels, height: pixels))
            return .image(image.flatMap { Self.jpeg($0, quality: 0.8) })

        case .quickPreview(let id, let maxPixelSize):
            let image = await library.quickPreview(for: try await asset(id), maxPixelSize: maxPixelSize)
            return .image(image.flatMap { Self.jpeg($0, quality: 0.85) })

        case .beginEditing(let id):
            let session = try await library.beginEditing(try await asset(id)) { progress($0, "Downloading from iCloud") }
            sessions.withLock { $0[id] = session }
            let info = try await decoder.info(for: session.original)
            let photoID = try? PhotoID.of(fileAt: session.original.url)
            return .session(RemoteSessionInfo(asset: session.asset, filename: session.filename, stored: session.stored, info: info, photoID: photoID?.rawValue))

        case .storedEdit(let id):
            return .stored(await library.storedEdit(for: try await asset(id)))

        case .decode(let id, let rawStage, let longEdge):
            let session = try await session(id)
            let decoded = try await decoder.decode(session.original, rawStage: rawStage, longEdge: longEdge)
            guard let bytes = decoded.serialized(), let compressed = try? (bytes as NSData).compressed(using: .lzfse) as Data else {
                throw DecodeError.renderFailed
            }
            return .decoded(compressed)

        case .aiMasks(let id, let recipe):
            let session = try await session(id)
            let store = AIMaskStore.store(for: recipe.analysisKey(for: session.original.key))
            let base = try await decoder.decode(session.original, rawStage: recipe.analysisStage, longEdge: 2560)
            try await store.prepare(recipe, base: base.image) { progress(nil, "Finding \($0.lowercased())") }
            let shapes = Set(recipe.masks.flatMap(\.components).map(\.shape).filter(\.isAI))
            return .masks(shapes.compactMap { shape in store.pngData(for: shape).map { RemoteMask(shape: shape, png: $0) } })

        case .fills(let id, let recipe):
            let session = try await session(id)
            let store = InpaintStore.store(for: recipe.analysisKey(for: session.original.key))
            let preview = try await decoder.decode(session.original, rawStage: recipe.analysisStage, longEdge: 2560)
            let decoder = self.decoder, source = session.original, stage = recipe.analysisStage
            try await store.prepare(recipe, preview: preview.image, fullResolution: {
                try await decoder.lazyImage(source, rawStage: stage, longEdge: nil).0
            }, progress: { done, total in
                progress(Double(done) / Double(max(total, 1)), total > 1 ? "\(done + 1) of \(total)" : nil)
            }, stepProgress: { fraction in progress(fraction, "diffusion \(Int(fraction * 100))%") })
            return .fills(store.fills(for: recipe))

        case .save(let id, let recipe, let files):
            let session = try await session(id)
            let data = try await Exporter.render(
                source: session.original, recipe: recipe, luts: merged(files), options: ExportOptions(format: .heic),
                queued: { progress(nil, "Waiting for earlier saves") },
                progress: { progress($0 * 0.9, nil) }
            )
            try await library.save(session, recipe: recipe, rendered: data, format: .heic)
            return .done(count: 1)

        case .export(let id, let recipe, let options, let files):
            let session = try await session(id)
            let url = try await Exporter.renderToFile(source: session.original, recipe: recipe, luts: merged(files), options: options,
                                                      baseName: (session.filename as NSString).deletingPathExtension) { progress($0, nil) }
            defer { try? FileManager.default.removeItem(at: url) }
            return .file(name: url.lastPathComponent, data: try Data(contentsOf: url))

        case .exportToLibrary(let id, let recipe, let options, let files):
            let session = try await session(id)
            let url = try await Exporter.renderToFile(source: session.original, recipe: recipe, luts: merged(files), options: options,
                                                      baseName: (session.filename as NSString).deletingPathExtension) { progress($0 * 0.9, nil) }
            defer { try? FileManager.default.removeItem(at: url) }
            try await library.addPhoto(fileAt: url)
            return .done(count: 1)

        case .revert(let id):
            try await library.revert(try await asset(id))
            return .done(count: 1)

        case .bulk(let change, let ids, let files):
            var targets: [PhotoAsset] = []
            for id in ids { targets.append(try await asset(id)) }
            let saved = try await BulkEditor.apply(change, to: targets, library: library, luts: merged(files), clock: clock) { state in
                progress(state.fraction, state.summary)
            } thumbnail: { _, _ in }
            return .done(count: saved)
        }
    }

    // MARK: Helpers

    private func asset(_ id: String) async throws -> PhotoAsset {
        if let known = assets.withLock({ $0[id] }) { return known }
        // Not listed yet this connection: look through all photos once.
        let list = await library.assets(in: .recents)
        let all = (0..<list.count).map { list[$0] }
        assets.withLock { known in for asset in all { known[asset.id] = asset } }
        guard let found = assets.withLock({ $0[id] }) else { throw LibraryError.noOriginal }
        return found
    }

    private func session(_ id: String) async throws -> EditingSession {
        if let open = sessions.withLock({ $0[id] }) { return open }
        let session = try await library.beginEditing(try await asset(id)) { _ in }
        sessions.withLock { $0[id] = session }
        return session
    }

    /// This device's LUTs plus any the iPad sent along.
    private func merged(_ files: [LUTFile]) -> any LUTProvider {
        var extra: [String: CubeLUT] = [:]
        for file in files {
            if let lut = try? CubeParser.parse(file.data, fallbackTitle: file.name) { extra[file.hash] = lut }
        }
        return MergedLUTs(base: luts, extra: extra)
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// LUTs from this device, plus ones another device sent for a render.
struct MergedLUTs: LUTProvider {
    var base: (any LUTProvider)?
    var extra: [String: CubeLUT]

    func lut(for ref: LUTRef) -> CubeLUT? { extra[ref.hash] ?? base?.lut(for: ref) }
}
