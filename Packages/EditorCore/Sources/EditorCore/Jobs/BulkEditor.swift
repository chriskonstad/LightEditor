import CoreGraphics
import CoreImage
import Foundation

/// A change applied to many photos at once.
public enum BulkChange: Sendable, Codable {
    case paste(RecipeClip, groups: Set<PasteGroup>, mode: PasteMode)
    case values([ParamKey: Double], mode: PasteMode)
    case preset(Preset, amount: Double)
    /// Each photo's own camera look, read from its file (`SourceInfo.cameraLook`);
    /// photos without one are left as they are.
    case cameraLook(amount: Double)
    case reset

    func apply(to recipe: Recipe, info: SourceInfo, stamp: HLCStamp) -> Recipe {
        let defaults = info.defaults
        return switch self {
        case .paste(let clip, let groups, let mode):
            recipe.pasting(clip, groups: groups, mode: mode, targetDefaults: defaults, stamp: stamp)
        case .values(let values, let mode):
            recipe.applying(values, mode: mode, defaults: defaults, stamp: stamp)
        case .preset(let preset, let amount):
            recipe.applying(preset, amount: amount, defaults: defaults, stamp: stamp)
        case .cameraLook(let amount):
            info.cameraLook.map { recipe.applying($0, amount: amount, defaults: defaults, stamp: stamp) } ?? recipe
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
///
/// Each photo is decoded once before its full render: a RAW 9 decode takes about as
/// long at 512 px as at 2560 px, so when the full render will want the 2560 px decode
/// (clarity, dehaze, AI masks, Remove fills) the thumbnail comes from that, and the
/// full render finds it in the decode cache. Full renders don't overlap each other or
/// those decodes, which all share the GPU (overlapping them was slower), but a batch's
/// save to the library runs while the next photos render.
public enum BulkEditor {
    public static let batchSize = 10

    public struct Progress: Sendable {
        public var fraction: Double
        /// Photos saved so far.
        public var completed: Int
        public var total: Int
        /// True while the looks are computed, before full renders start.
        public var preparing: Bool = false
        /// The photo being rendered at full size (1-based), once full renders start.
        public var rendering: Int?

        public var remaining: Int { total - completed }
        public var summary: String {
            if preparing { return "Preparing · \(total) photos" }
            if let rendering { return "Rendering \(rendering) of \(total) · \(completed) done" }
            return "\(remaining) left · \(completed) of \(total) saved"
        }
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
            var recipe = change.apply(to: base, info: info, stamp: clock.now())
            // Pasted auto straighten finds each photo's own level.
            if case .crop(let geometry)? = recipe[.crop], geometry.auto?.isResolved == false,
               let decoded = try? await decoder.decode(session.original, rawStage: recipe.analysisStage, longEdge: 1024),
               let resolved = await AutoStraightener.resolve(recipe, source: session.original, image: decoded.image, stamp: clock.now()) {
                recipe = resolved
            }
            prepared.append((session, recipe))
            let aiMasks = try? await Exporter.prepareAIMasks(recipe, source: session.original, decoder: decoder)
            let needsLarge = Exporter.usesPresenceGuide(recipe) || recipe.masks.contains(where: \.usesAI)
                || recipe.retouches.contains { $0.kind == .remove }
            if let decoded = try? await decoder.decode(session.original, rawStage: recipe.rawStage, longEdge: needsLarge ? 2560 : 512),
               let image = ThumbnailRenderer.render(recipe, base: thumbnailBase(decoded.image), inputs: {
                   var inputs = GradeInputs(defaults: info.defaults, luts: luts, aiMasks: aiMasks)
                   inputs.inpaints = InpaintStore.store(for: recipe.analysisKey(for: session.original.key))
                   return inputs
               }(), longEdge: 384) {
                thumbnail(asset.id, image)
            }
            progress(Progress(fraction: Double(index + 1) / Double(total) * 0.25, completed: 0, total: total, preparing: true))
        }

        // Pass 2: full renders, committed in batches. One batch saves while the next
        // renders; they finish in order.
        var pending: [PendingEdit] = []
        var saved = 0
        var saving: Task<Int, any Error>?
        for (index, (session, recipe)) in prepared.enumerated() {
            try Task.checkCancellation()
            // A full-size render takes seconds, so progress moves within each photo too;
            // a bar that sits still looks frozen, and iOS may end a background task that
            // seems stalled.
            let start = 0.25 + Double(index) / Double(total) * 0.75
            let span = 0.75 / Double(total)
            progress(Progress(fraction: start, completed: index, total: total, rendering: index + 1))
            let data = try await Exporter.render(source: session.original, recipe: recipe, luts: luts, options: ExportOptions(format: format), decoder: decoder, progress: { fraction in
                progress(Progress(fraction: start + fraction * span, completed: index, total: total, rendering: index + 1))
            })
            pending.append(PendingEdit(session: session, recipe: recipe, rendered: data, format: format))
            if pending.count == batchSize || index == prepared.count - 1 {
                saved += try await saving?.value ?? 0
                let batch = pending
                pending.removeAll()
                saving = Task {
                    try await library.saveBatch(batch)
                    return batch.count
                }
            }
            progress(Progress(fraction: 0.25 + Double(index + 1) / Double(total) * 0.75, completed: index + 1, total: total))
        }
        saved += try await saving?.value ?? 0
        return saved
    }

    /// A 2560 px decode shrunk smoothly to 512 px first: the thumbnail's own
    /// downscale is a plain resample, which aliases from that far.
    private static func thumbnailBase(_ image: CIImage) -> CIImage {
        let scale = 512 / max(image.extent.width, image.extent.height)
        guard scale < 1 else { return image }
        return image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
    }
}
