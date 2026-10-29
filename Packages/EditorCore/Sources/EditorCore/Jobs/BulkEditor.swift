import CoreGraphics
import Foundation

/// A change applied to many photos at once.
public enum BulkChange: Sendable, Codable {
    case paste(RecipeClip, groups: Set<PasteGroup>, mode: PasteMode)
    case values([ParamKey: Double], mode: PasteMode)
    case preset(Preset, amount: Double)
    case reset

    func apply(to recipe: Recipe, defaults: PhotoDefaults, stamp: HLCStamp) -> Recipe {
        switch self {
        case .paste(let clip, let groups, let mode):
            recipe.pasting(clip, groups: groups, mode: mode, targetDefaults: defaults, stamp: stamp)
        case .values(let values, let mode):
            recipe.applying(values, mode: mode, defaults: defaults, stamp: stamp)
        case .preset(let preset, let amount):
            recipe.applying(preset, amount: amount, defaults: defaults, stamp: stamp)
        case .reset:
            {
                var copy = recipe
                copy.resetAll(at: stamp)
                return copy
            }()
        }
    }
}

/// Applies a change across a selection.
///
/// Thumbnails come first, so the grid shows the new look within moments; full
/// renders follow and are committed to the library in batches, so Photos asks for
/// permission once per batch rather than once per photo.
public enum BulkEditor {
    public static let batchSize = 10

    public struct Progress: Sendable {
        public var fraction: Double
        /// Photos saved so far.
        public var completed: Int
        public var total: Int
        /// True while the looks are computed, before full renders start.
        public var preparing: Bool = false

        public var remaining: Int { total - completed }
        public var summary: String { preparing ? "Preparing · \(total) photos" : "\(remaining) left · \(completed) of \(total) saved" }
    }

    @discardableResult
    public static func apply(
        _ change: BulkChange,
        to assets: [PhotoAsset],
        library: any PhotoLibrary,
        luts: (any LUTProvider)?,
        clock: HybridLogicalClock,
        decoder: RawDecoder = .shared,
        format: ExportFormat = .heic,
        progress: @escaping @Sendable (Progress) -> Void,
        thumbnail: @escaping @Sendable (String, CGImage) -> Void
    ) async throws -> Int {
        let total = assets.count
        guard total > 0 else { return 0 }
        var prepared: [(EditingSession, Recipe)] = []

        // Pass 1: load, compute recipes and show thumbnails.
        for (index, asset) in assets.enumerated() {
            try Task.checkCancellation()
            let session = try await library.beginEditing(asset) { _ in }
            let info = try await decoder.info(for: session.original)
            var base: Recipe
            if case .ours(let stored) = session.stored {
                base = stored
            } else {
                base = Recipe(decoder: DecoderPin(version: info.decoderVersion))
            }
            var recipe = change.apply(to: base, defaults: info.defaults, stamp: clock.now())
            // Pasted auto straighten finds each photo's own level.
            if case .crop(let geometry)? = recipe[.crop], geometry.auto?.isResolved == false,
               let decoded = try? await decoder.decode(session.original, rawStage: recipe.analysisStage, longEdge: 1024),
               let resolved = await AutoStraightener.resolve(recipe, source: session.original, image: decoded.image, stamp: clock.now()) {
                recipe = resolved
            }
            prepared.append((session, recipe))
            let aiMasks = try? await Exporter.prepareAIMasks(recipe, source: session.original, decoder: decoder)
            if let decoded = try? await decoder.decode(session.original, rawStage: recipe.rawStage, longEdge: 512),
               let image = ThumbnailRenderer.render(recipe, base: decoded.image, inputs: {
                   var inputs = GradeInputs(defaults: info.defaults, luts: luts, aiMasks: aiMasks)
                   inputs.inpaints = InpaintStore.store(for: recipe.analysisKey(for: session.original.key))
                   return inputs
               }(), longEdge: 384) {
                thumbnail(asset.id, image)
            }
            progress(Progress(fraction: Double(index + 1) / Double(total) * 0.25, completed: 0, total: total, preparing: true))
        }

        // Pass 2: full renders, committed in batches.
        var pending: [PendingEdit] = []
        var saved = 0
        for (index, (session, recipe)) in prepared.enumerated() {
            try Task.checkCancellation()
            let data = try await Exporter.render(source: session.original, recipe: recipe, luts: luts, options: ExportOptions(format: format))
            pending.append(PendingEdit(session: session, recipe: recipe, rendered: data, format: format))
            if pending.count == batchSize || index == prepared.count - 1 {
                try await library.saveBatch(pending)
                saved += pending.count
                pending.removeAll()
            }
            progress(Progress(fraction: 0.25 + Double(index + 1) / Double(total) * 0.75, completed: index + 1, total: total))
        }
        return saved
    }
}
