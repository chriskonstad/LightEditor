import CoreImage
import EditorCore
import Foundation
import Observation

/// State for editing one photo.
///
/// The recipe is the single source of truth. Every change rebuilds the Core Image
/// graph on the cached decode (cheap) and hands it to the preview renderer, which
/// draws at most once per frame. RAW-stage changes re-decode in the background
/// while the old decode stays on screen.
@MainActor
@Observable
final class EditorModel: Identifiable {
    enum Phase: Equatable {
        case opening(String)
        case decoding
        case ready
        case failed(String)
    }

    /// In picker order. Presets come first: they set the sliders the other tabs
    /// then fine-tune. The editor still opens on Light.
    enum Tab: String, CaseIterable, Identifiable {
        case presets, light, color, grade, detail, masks
        var id: String { rawValue }
        var title: String { rawValue.capitalized }

        var systemImage: String {
            switch self {
            case .light: "sun.max"
            case .color: "drop.halffull"
            case .grade: "circle.lefthalf.filled"
            case .detail: "camera.aperture"
            case .masks: "circle.dashed.inset.filled"
            case .presets: "square.grid.2x2"
            }
        }
    }

    struct Step: Identifiable, Equatable {
        let id = UUID()
        var label: String
        var recipe: Recipe
        var date = Date()
    }

    let app: AppModel
    let asset: PhotoAsset
    nonisolated let id: String

    private(set) var session: EditingSession?
    private(set) var info: SourceInfo?
    private(set) var filename: String = ""
    private(set) var phase: Phase = .opening("Opening…")
    private(set) var isRedecoding = false
    private(set) var foreignEdit: String?

    private(set) var recipe = Recipe() { didSet { render() } }
    private var savedParams: [ParamKey: ParamValue] = [:]
    private(set) var history: [Step] = []
    private(set) var historyIndex = 0
    var snapshots: [Step] = []

    let renderer = PreviewRenderer()
    var compare = false { didSet { render() } }
    var showClipping = false { didSet { render() } }
    /// Starts with the divider in the middle of what's on screen.
    var splitView = false { didSet { if splitView { splitPosition = 0.5 }; render() } }
    /// Where the before/after divider sits, as a fraction of the view's width,
    /// so it stays put while the photo zooms and pans under it.
    var splitPosition = 0.5 { didSet { if renderer.split != nil { renderer.split = splitPosition } } }
    /// Split is off while cropping, masking or retouching, which show the uncropped frame.
    var showsSplit: Bool { splitView && !compare && !isCropping && !showsOriginalFrame }
    /// Parameters temporarily hidden while their control is pressed and held.
    private(set) var hiddenKeys: Set<ParamKey> = [] { didSet { render() } }
    /// "Without Exposure", shown on the photo while a control is held.
    private(set) var hiddenLabel: String?
    /// While an HSL swatch or slider is held: show which colors that band affects.
    var hslSelection: HueBand? {
        didSet {
            hiddenLabel = hslSelection.map { "Showing \($0.displayName.lowercased())s" }
            render()
        }
    }

    // Masks
    var selectedMaskID: UUID? { didSet { render() } }
    var selectedComponentID: UUID?
    var showMaskOverlay = true { didSet { render() } }
    /// AI shapes being computed right now, for status rows.
    var computingAI: Set<MaskShape> = []
    /// AI shapes Vision found nothing for, with the reason.
    var aiFailures: [MaskShape: String] = [:]
    /// Brush settings, shared by every brush component.
    var brushSize = 0.04
    var brushFeather = 0.5
    var brushFlow = 1.0
    var brushErase = false
    /// The stroke being painted, kept outside the recipe until the finger lifts.
    var paintingStroke: BrushStroke?
    /// AI masks and fills for this photo, per lens-correction setting (which moves pixels).
    var aiStore: AIMaskStore? { session.map { AIMaskStore.store(for: recipe.analysisKey(for: $0.original.key)) } }

    // Retouch
    /// Retouch starts at Fit; pinch with two fingers to zoom in while painting.
    var isRetouching = false { didSet { if isRetouching != oldValue { zoom = .fit }; render() } }
    var retouchKind: RetouchSpot.Kind = Inpainter.shared.isAvailable ? .remove : .heal
    var retouchBrushSize = 0.03
    /// The engine new Remove spots use: the last one picked, else LaMa + diffusion when this
    /// build has it and its license was accepted (see `DiffusionTerms`).
    var removeEngine: RemoveEngine = {
        let diffusionReady = DiffusionInpainter.shared.isAvailable && DiffusionTerms.accepted
        if let saved = RemoveEngine(rawValue: UserDefaults.standard.string(forKey: "removeEngine") ?? ""),
           saved != .diffusion || diffusionReady {
            return saved
        }
        return diffusionReady ? .diffusion : .standard
    }() {
        didSet { UserDefaults.standard.set(removeEngine.rawValue, forKey: "removeEngine") }
    }
    var selectedSpotID: UUID?
    var showSpots = true
    /// Remove spots whose fill is being computed.
    var inpainting: Set<UUID> = []
    var inpaintFailures: [UUID: String] = [:]
    var inpaintStore: InpaintStore? { session.map { InpaintStore.store(for: recipe.analysisKey(for: $0.original.key)) } }
    /// Masks are drawn on the uncropped original, so mask editing shows the whole frame.
    var isEditingMasks: Bool { tab == .masks && !isCropping && !isRetouching }
    /// Masks and retouch work on the uncropped original.
    var showsOriginalFrame: Bool { isEditingMasks || isRetouching }
    var isCropping = false { didSet { render() } }
    /// `.actual(scale:)` is relative to the original's full resolution: 1 is 100%,
    /// one original pixel per screen pixel.
    var zoom: PreviewZoom = .fit {
        didSet {
            if case .fit = zoom { pan = .zero }
            // Draw at the new zoom right away; sharper tiles swap in as they decode.
            render()
        }
    }
    var tab: Tab = .light {
        didSet {
            guard (oldValue == .masks) != (tab == .masks) else { return }
            if tab == .masks, case .actual = zoom { zoom = .fit }
            render()
        }
    }
    var showExport = false
    var showPaste = false
    var selectedBand: HueBand = .red
    private(set) var histogram = Histogram.empty

    /// Presets tab state: the recipe before the preset, so Amount can re-apply it.
    private(set) var activePreset: Preset?
    private var presetBase: Recipe?
    var presetAmount = 1.0

    private(set) var base: DecodedImage?
    private var baseRawStage: RawStageParams?
    private var placeholder: CIImage?
    private var decodeTask: Task<Void, Never>?
    private var histogramTask: Task<Void, Never>?
    private var draftWrite: Task<Void, Never>?
    private var historyNoticeTask: Task<Void, Never>?
    /// "Undo: Exposure +0.50", shown on the photo briefly after undo or redo.
    private(set) var historyNotice: String?
    private var histogramPending = false
    private var dragStart: Recipe?

    init(app: AppModel, asset: PhotoAsset) {
        self.app = app
        self.asset = asset
        self.id = asset.id
        renderer.onFrame = { [weak self] in self?.frameDrawn($0) }
    }

    var defaults: PhotoDefaults { info?.defaults ?? .generic }
    var isDirty: Bool { recipe.params != savedParams }
    var canUndo: Bool { historyIndex > 0 }
    var canRedo: Bool { historyIndex < history.count - 1 }
    var badge: String { info?.badge ?? "" }

    /// Whether a recipe value for this tab's group differs from the default.
    func hasEdits(_ group: PasteGroup) -> Bool { recipe.hasEdits(in: group) }

    // MARK: Opening

    func open() async {
        let library = app.library
        let asset = self.asset
        // 1. The library's current rendition, instantly.
        if let quick = await library.quickPreview(for: asset, maxPixelSize: 1600) {
            placeholder = CIImage(cgImage: quick)
            render()
        }
        // 2. The original, downloading from iCloud if needed.
        let task = app.jobs.run("Loading original") { reporter in
            try await library.beginEditing(asset) { reporter.progress($0, detail: "Downloading from iCloud") }
        }
        do {
            let session = try await task.value
            self.session = session
            filename = session.filename
            if placeholder == nil, let embedded = await Self.embeddedPreview(session.original.url) {
                placeholder = CIImage(cgImage: embedded.image)
                render()
            }
            let info = try await RawDecoder.shared.info(for: session.original)
            self.info = info

            var start = Recipe(decoder: DecoderPin(version: info.decoderVersion))
            switch session.stored {
            case .ours(let stored):
                start = stored
                savedParams = stored.params
            case .foreign(let identifier):
                foreignEdit = "Edited in \(Self.appName(identifier)). Editing starts from the original, and saving replaces those edits."
            case .none:
                break
            }
            // Edits that never reached the library, e.g. after a crash.
            if let draft = RecipeDrafts.shared.load(for: asset.id), draft.params != start.params {
                start = draft
                app.showToast("Restored unsaved edits")
            }
            history = [Step(label: "Open", recipe: start)]
            historyIndex = 0
            recipe = start
            phase = .decoding
            hashPhotoID(session.original)
            computeMissingAIMasks()
            computeMissingInpaints()
            await decode(rawStage: recipe.rawStage, initial: true)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private static func embeddedPreview(_ url: URL) async -> SendableImage? {
        await Task.detached(priority: .userInitiated) {
            EmbeddedPreview.load(url, maxPixelSize: 1600).map(SendableImage.init)
        }.value
    }

    private static func appName(_ identifier: String) -> String {
        identifier.hasPrefix("com.apple.") ? "Photos" : "another app"
    }

    /// Computes the content-hash photo ID in the background. It never changes the
    /// look, so it isn't a history step.
    private func hashPhotoID(_ source: PhotoSource) {
        // Remote photos get their identity from the device that has the file.
        guard recipe.photoID == .pending, !source.isRemote else { return }
        let url = source.url
        let task = app.jobs.run("Indexing", detail: filename) { _ in try PhotoID.of(fileAt: url) }
        Task {
            guard let id = try? await task.value else { return }
            var updated = recipe
            updated.photoID = id
            if !isDirty { savedParams = updated.params }
            recipe = updated
            for index in history.indices { history[index].recipe.photoID = id }
        }
    }

    // MARK: Decoding

    private var longEdge: Int { 2560 }

    private func decode(rawStage: RawStageParams, initial: Bool) async {
        guard let session else { return }
        decodeTask?.cancel()
        let source = session.original
        let longEdge = self.longEdge
        let label = info?.isRAW == true ? (initial ? "Decoding RAW \(info?.decoderVersion ?? "")" : "Re-decoding RAW \(info?.decoderVersion ?? "")") : "Decoding"
        if !initial { isRedecoding = true }
        let job = app.jobs.run(label, detail: filename) { _ in
            try await RawDecoder.shared.decode(source, rawStage: rawStage, longEdge: longEdge)
        }
        let task = Task { [weak self] in
            do {
                let decoded = try await job.value
                guard let self, !Task.isCancelled else { return }
                self.base = decoded
                self.baseRawStage = rawStage
                self.resetPreviewSources(for: decoded)
                self.phase = .ready
                self.isRedecoding = false
                self.render()
                self.resolveAutoStraighten()
            } catch is CancellationError {
                job.cancel()
            } catch {
                self?.phase = .failed(error.localizedDescription)
                self?.isRedecoding = false
            }
        }
        decodeTask = task
        await task.value
    }

    private var redecodeDebounce: Task<Void, Never>?

    private func scheduleRedecodeIfNeeded() {
        guard phase == .ready || isRedecoding, let baseRawStage, recipe.rawStage != baseRawStage else { return }
        redecodeDebounce?.cancel()
        let rawStage = recipe.rawStage
        isRedecoding = true
        redecodeDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.decode(rawStage: rawStage, initial: false)
        }
    }

    // MARK: Rendering

    /// The recipe as displayed: held controls are left out, and while cropping the
    /// frame is corrected and straightened but uncropped.
    private var displayRecipe: Recipe {
        var copy = recipe
        let stamp = HLCStamp(millis: 0, node: "display")
        for key in hiddenKeys { copy.set(key, nil, at: stamp) }
        if isCropping, case .crop(var geometry)? = recipe[.crop] {
            geometry.rect = .full
            copy.set(.crop, .crop(geometry), at: stamp)
        }
        return copy
    }

    /// Shows the photo without `keys` while a control is pressed and held.
    func setHidden(_ keys: Set<ParamKey>, hidden: Bool, label: String) {
        guard keys.contains(where: { recipe[$0] != nil }) || !hidden else { return }
        hiddenKeys = hidden ? keys : []
        hiddenLabel = hidden ? "Without \(label.lowercased())" : nil
    }

    var displayedImageSize: CGSize { renderer.image?.extent.size ?? .zero }

    /// The pan offset in drawable pixels. Kept here so on-photo overlays follow it.
    var pan: CGPoint {
        get { viewport.pan }
        set {
            viewport.pan = newValue
            renderer.pan = newValue
            noteInteraction()
            requestVisibleTiles()
        }
    }
    /// Observable copy of the renderer's pan, so overlays redraw when it changes.
    private(set) var viewport = Viewport()
    struct Viewport: Equatable { var pan: CGPoint = .zero }

    /// The photo's rect in a view of `viewSize` points, at the current zoom and pan.
    func photoFrame(in viewSize: CGSize) -> CGRect {
        _ = viewport  // Observe pans.
        _ = zoom
        let drawable = renderer.lastDrawableSize
        let size = displayedImageSize
        guard drawable.width > 0, viewSize.width > 0, size.width > 0 else {
            guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: viewSize) }
            let scale = min(viewSize.width / size.width, viewSize.height / size.height)
            return CGRect(x: (viewSize.width - size.width * scale) / 2, y: (viewSize.height - size.height * scale) / 2,
                          width: size.width * scale, height: size.height * scale)
        }
        let ratio = viewSize.width / drawable.width
        let rect = renderer.imageRect(in: drawable)
        return CGRect(x: rect.minX * ratio, y: rect.minY * ratio, width: rect.width * ratio, height: rect.height * ratio)
    }

    /// The photo's long edge at Fit, in view points; brush sizes are relative to it,
    /// so they stay the same size on screen at any zoom.
    func fitLongEdge(in viewSize: CGSize) -> CGFloat {
        let size = displayedImageSize
        guard size.width > 0, size.height > 0 else { return max(viewSize.width, viewSize.height) }
        let scale = min(viewSize.width / size.width, viewSize.height / size.height)
        return max(size.width, size.height) * scale
    }

    // MARK: Zoom

    /// The original's long edge in pixels.
    private var nativeLongEdge: Double {
        guard let size = info?.nativeSize, size.width > 0 else { return Double(longEdge) }
        return max(size.width, size.height)
    }

    /// The zoom as a fraction of the original's resolution, including at Fit.
    func zoomScale(drawableSize: CGSize) -> Double {
        switch zoom {
        case .actual(let scale): return scale
        case .fit:
            guard let source = renderer.image?.extent.size, source.width > 0, drawableSize.width > 0 else { return 0 }
            let display = renderer.displayScale(for: source, drawableSize: drawableSize)
            return display * max(sourceLongEdge, 1) / nativeLongEdge
        }
    }

    /// Zooms to `scale` (of the original) keeping the image point under `anchor`
    /// still. All geometry is in drawable pixels with a top-left origin.
    func zoom(to scale: Double, anchor: CGPoint, from startRect: CGRect, startScale: Double, drawableSize: CGSize) {
        let fitScale = zoomScale(forFitIn: drawableSize)
        let clamped = min(max(scale, fitScale), 8)
        if clamped <= fitScale * 1.01 {
            zoom = .fit
            return
        }
        let ratio = clamped / max(startScale, 1e-6)
        let size = CGSize(width: startRect.width * ratio, height: startRect.height * ratio)
        let fraction = CGPoint(x: (anchor.x - startRect.minX) / max(startRect.width, 1), y: (anchor.y - startRect.minY) / max(startRect.height, 1))
        let origin = CGPoint(x: anchor.x - fraction.x * size.width, y: anchor.y - fraction.y * size.height)
        pan = CGPoint(x: origin.x - (drawableSize.width - size.width) / 2, y: origin.y - (drawableSize.height - size.height) / 2)
        noteInteraction()
        zoom = .actual(scale: clamped)
    }

    func zoomScale(forFitIn drawableSize: CGSize) -> Double {
        guard let source = renderer.image?.extent.size, source.width > 0, drawableSize.width > 0 else { return 0.05 }
        let fit = min(drawableSize.width / source.width, drawableSize.height / source.height)
        return fit * max(sourceLongEdge, 1) / nativeLongEdge
    }

    private func render() {
        scheduleRedecodeIfNeeded()
        guard let decoded = base else {
            renderer.image = placeholder
            sourceLongEdge = placeholder.map { Double(max($0.extent.width, $0.extent.height)) } ?? Double(longEdge)
            return
        }
        let (source, tileCache, reduced) = previewSource(decoded)
        sourceLongEdge = Double(max(source.extent.width, source.extent.height))
        // The renderer scales the image it draws; convert from original-relative zoom.
        if case .actual(let scale) = zoom {
            renderer.zoom = .actual(scale: scale * nativeLongEdge / max(sourceLongEdge, 1))
        } else {
            renderer.zoom = .fit
        }
        renderedReduced = reduced
        if compare {
            renderer.before = nil
            renderer.split = nil
            renderer.image = source
            visibleTiles = tileCache.map { ($0, source, source) }
            requestVisibleTiles()
            updatePreviewStatus(reduced: reduced)
            return
        }
        var inputs = GradeInputs(
            defaults: defaults, luts: app.lutStore, applyGeometry: !showsOriginalFrame, showClipping: showClipping,
            aiMasks: aiStore, maskOverlay: isEditingMasks && showMaskOverlay ? selectedMaskID : nil
        )
        inputs.hslSelection = hslSelection
        inputs.inpaints = inpaintStore
        inputs.presenceGuide = presenceGuide(forSourceLongEdge: sourceLongEdge, decoded)
        let image = GradeGraph.apply(displayRecipe, to: source, inputs: inputs)
        var geometry: CIImage?
        if showsSplit || tileCache != nil {
            // Crop and perspective only: the before side of split view, and how
            // on-screen pixels map back to tiles.
            var geometryOnly = Recipe()
            let stamp = HLCStamp(millis: 0, node: "display")
            for key in [ParamKey.crop, .perspectiveVertical, .perspectiveHorizontal] {
                if let value = displayRecipe[key] { geometryOnly.set(key, value, at: stamp) }
            }
            geometry = GradeGraph.apply(geometryOnly, to: source, inputs: GradeInputs(defaults: defaults, applyGeometry: !showsOriginalFrame))
        }
        if showsSplit {
            // Before on the left of the divider, after on the right, same geometry.
            renderer.before = geometry
            renderer.split = splitPosition
        } else {
            renderer.before = nil
            renderer.split = nil
        }
        renderer.image = image
        if let tileCache, let geometry {
            visibleTiles = (tileCache, geometry, source)
            requestVisibleTiles()
        } else {
            visibleTiles = nil
        }
        updatePreviewStatus(reduced: reduced)
        scheduleHistogram()
    }

    // MARK: Preview sources

    /// What the canvas is still working on, shown next to the title. Saving and
    /// exporting the full image are jobs in the job tray instead.
    enum PreviewStatus: Equatable {
        /// A quick, lower-resolution preview is showing while you drag; the sharp one follows.
        case refining
        /// Zoomed in: detail from the original is still decoding.
        case loadingDetail
    }
    private(set) var previewStatus: PreviewStatus?

    /// Smaller copies of `base`, smallest first: grading a screen-sized image is
    /// several times cheaper than grading 2560 px and scaling it down.
    @ObservationIgnored private var proxies: [DecodedImage] = []
    @ObservationIgnored private var proxyTask: Task<Void, Never>?
    private static let proxySizes = [256, 640, 1280]
    /// Tiles of the original for zoomed-in previews, by level: 1 is full
    /// resolution, 0.5 half. Decoded only where the photo is on screen.
    @ObservationIgnored private var tiles: [Double: TileCache] = [:]
    /// Tiles from before a RAW-stage edit, shown under the new ones while they
    /// decode so the zoomed-in photo doesn't go soft in between.
    @ObservationIgnored private var staleTiles: TileCache?
    @ObservationIgnored private var loadingTiles: Set<Double> = []
    @ObservationIgnored private var tileRenderPending = false
    /// The last tiled render, so panning can ask for the tiles coming on screen.
    @ObservationIgnored private var visibleTiles: (cache: TileCache, geometry: CIImage, source: CIImage)?
    /// The long edge of the image the canvas is drawing, before crop.
    @ObservationIgnored private var sourceLongEdge: Double = 2560
    /// Set while a slider drags or the photo zooms or pans; ends after a short pause.
    @ObservationIgnored private var interacting = false
    @ObservationIgnored private var interactionEnd: Task<Void, Never>?
    /// How long full-quality frames take; above a frame's time, drags use a smaller preview.
    @ObservationIgnored private(set) var fullQualityFrameTime: Duration = .zero
    @ObservationIgnored private var renderedReduced = false
    private static let frameBudget = Duration.milliseconds(16)

    /// The preview decode changed (opening, or a RAW-stage edit): drop what was
    /// made from the old one and start the smaller copies.
    private func resetPreviewSources(for decoded: DecodedImage) {
        for cache in tiles.values { cache.cancelAll() }
        staleTiles = visibleTiles?.cache
        tiles = [:]
        loadingTiles = []
        visibleTiles = nil
        proxies = []
        proxyTask?.cancel()
        let sizes = Self.proxySizes
        proxyTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { () -> [DecodedImage] in
                var made: [DecodedImage] = []
                var from = decoded
                // Largest first, each from the one before.
                for size in sizes.reversed() {
                    guard let next = try? from.downscaled(toLongEdge: size) else { break }
                    made.insert(next, at: 0)
                    from = next
                }
                return made
            }.value
            guard let self, !Task.isCancelled, self.base?.pixelBuffer === decoded.pixelBuffer else { return }
            self.proxies = built
            self.render()
        }
    }

    /// The long edge, in pixels, the uncropped photo needs to look sharp at the current zoom.
    private var neededLongEdge: Double {
        switch zoom {
        case .actual(let scale):
            return scale * nativeLongEdge
        case .fit:
            let drawable = renderer.lastDrawableSize
            guard drawable.width > 0 else { return Double(longEdge) }
            if let shown = renderer.image?.extent.size, shown.width > 0 {
                return renderer.displayScale(for: shown, drawableSize: drawable) * sourceLongEdge
            }
            return max(drawable.width, drawable.height)
        }
    }

    /// The image to grade: the smallest one that's sharp at the current zoom.
    /// While dragging, if full-quality frames are slow, one a step smaller.
    /// Zoomed in past the 2560 px decode, tiles of the original over it.
    private func previewSource(_ decoded: DecodedImage) -> (CIImage, TileCache?, reduced: Bool) {
        let needed = neededLongEdge
        let baseLong = Double(max(decoded.size.width, decoded.size.height))
        let tiled = session.map { !$0.original.isRemote && $0.original.isRAW } ?? false
        if tiled, needed > baseLong * 1.05 {
            let half = nativeLongEdge * 0.5
            let level = (half > baseLong * 1.2 && needed <= half * 1.05) ? 0.5 : 1
            // Sharper tiles over coarser ones over the decode, so zooming in shows
            // something at once.
            var image = decoded.image
            for coarser in [0.5, 1.0] where coarser < level {
                if let cache = tiles[coarser] { image = cache.image(over: image) }
            }
            if let staleTiles, staleTiles.level == level { image = staleTiles.image(over: image) }
            if let cache = tiles[level] {
                return (cache.image(over: image), cache, false)
            }
            loadTiles(level: level)
            return (image, nil, true)
        }
        staleTiles = nil
        let slow = interacting && fullQualityFrameTime > Self.frameBudget
        let target = needed * (slow ? 0.5 : 1)
        let candidates = proxies + [decoded]
        let pick = candidates.first { Double(max($0.size.width, $0.size.height)) >= target * 0.97 } ?? decoded
        let pickLong = Double(max(pick.size.width, pick.size.height))
        return (pick.image, nil, pickLong < min(needed, baseLong) * 0.97)
    }

    /// For big sources (the 2560 px decode, or tiles), clarity's and dehaze's
    /// wide blurs come from a smaller copy; zoomed-in frames with them on drop
    /// from 17 to 3 ms on an M4 Pro.
    private func presenceGuide(forSourceLongEdge sourceLong: Double, _ decoded: DecodedImage) -> CIImage? {
        guard sourceLong >= 2000 else { return nil }
        return (proxies + [decoded]).last { Double(max($0.size.width, $0.size.height)) * 1.5 <= sourceLong }?.image
    }

    private func loadTiles(level: Double) {
        guard tiles[level] == nil, !loadingTiles.contains(level), let session, let rawStage = baseRawStage else { return }
        loadingTiles.insert(level)
        let source = session.original
        let longEdge = level < 1 ? Int(nativeLongEdge * level) : nil
        Task { [weak self] in
            let loaded = try? await RawDecoder.shared.lazyImage(source, rawStage: rawStage, longEdge: longEdge)
            guard let self else { return }
            self.loadingTiles.remove(level)
            // A re-decode since started this has its own tiles.
            guard let (image, _) = loaded, self.baseRawStage == rawStage else { return }
            self.tiles[level] = TileCache(source: image, level: level, limit: level < 1 ? 12 : 24) { [weak self] in
                Task { @MainActor in self?.tileArrived() }
            }
            self.render()
        }
    }

    private func tileArrived() {
        guard !tileRenderPending else { return }
        tileRenderPending = true
        Task { @MainActor in
            tileRenderPending = false
            render()
        }
    }

    /// Asks for the tiles under the visible part of the photo.
    private func requestVisibleTiles() {
        guard let (cache, geometry, source) = visibleTiles, let shown = renderer.image else { return }
        let drawable = renderer.lastDrawableSize
        guard drawable.width > 0, shown.extent.width > 0 else { return }
        let rect = renderer.imageRect(in: drawable)
        let visible = rect.intersection(CGRect(origin: .zero, size: drawable))
        guard !visible.isNull, !visible.isEmpty else { return }
        // Drawable pixels (top-left origin) to the shown image's coordinates.
        let extent = shown.extent
        let scale = rect.width / extent.width
        let onScreen = CGRect(
            x: extent.minX + (visible.minX - rect.minX) / scale, y: extent.minY + (rect.maxY - visible.maxY) / scale,
            width: visible.width / scale, height: visible.height / scale
        )
        var needed = geometry.regionOfInterest(for: source, in: onScreen)
        if needed.isNull || needed.isInfinite || needed.isEmpty { needed = onScreen }
        cache.request(needed.insetBy(dx: -96, dy: -96))
        updatePreviewStatus(reduced: renderedReduced)
    }

    private func updatePreviewStatus(reduced: Bool) {
        if let cache = visibleTiles?.cache, cache.level == staleTiles?.level, cache.pendingCount == 0 { staleTiles = nil }
        let status: PreviewStatus?
        if case .actual = zoom, reduced || (visibleTiles?.cache.pendingCount ?? 0) > 0 {
            status = .loadingDetail
        } else {
            status = reduced ? .refining : nil
        }
        if previewStatus != status { previewStatus = status }
    }

    /// Marks a drag, pinch or pan; a sharp frame follows once it pauses.
    private func noteInteraction() {
        interacting = true
        interactionEnd?.cancel()
        interactionEnd = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            self.interacting = false
            if self.renderedReduced { self.render() }
        }
    }

    private func frameDrawn(_ time: Duration) {
        if !renderedReduced { fullQualityFrameTime = time }
    }

    private func scheduleHistogram() {
        guard histogramTask == nil else {
            histogramPending = true
            return
        }
        guard let image = histogramImage() else { return }
        let box = UncheckedImage(image)
        histogramTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Histogram.compute(box.image) }.value
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            self.histogram = result
            self.histogramTask = nil
            if self.histogramPending {
                self.histogramPending = false
                self.scheduleHistogram()
            }
        }
    }

    /// The edited photo from the smallest proxy, without on-screen overlays: the
    /// histogram is 256 px wide, so grading more pixels only costs time.
    private func histogramImage() -> CIImage? {
        guard let small = proxies.first ?? base else { return nil }
        var inputs = GradeInputs(defaults: defaults, luts: app.lutStore, applyGeometry: !showsOriginalFrame, aiMasks: aiStore)
        inputs.inpaints = inpaintStore
        return GradeGraph.apply(displayRecipe, to: small.image, inputs: inputs)
    }

    // MARK: Editing

    func value(_ key: ParamKey) -> Double { recipe.scalar(key, defaults: defaults) }

    /// Updates a parameter live, e.g. while a slider drags. Call `commit` at the end.
    func setLive(_ key: ParamKey, _ value: Double) {
        if dragStart == nil { dragStart = recipe }
        noteInteraction()
        clearPresetPreview()
        recipe.setScalar(key, value, at: app.clock.now())
    }

    func setLive(_ key: ParamKey, _ value: ParamValue?) {
        if dragStart == nil { dragStart = recipe }
        noteInteraction()
        clearPresetPreview()
        recipe.set(key, value, at: app.clock.now())
    }

    /// Ends a live change and records one history step.
    func commit(_ key: ParamKey) {
        dragStart = nil
        pushHistory(label: Self.label(for: key, in: recipe, defaults: defaults))
    }

    func set(_ key: ParamKey, _ value: ParamValue?) {
        clearPresetPreview()
        recipe.set(key, value, at: app.clock.now())
        pushHistory(label: Self.label(for: key, in: recipe, defaults: defaults))
    }

    /// Lens correction moves pixels, so AI masks and fills are recomputed for the new geometry.
    func setLensCorrection(_ on: Bool) {
        set(.lensCorrection, on ? nil : .scalar(0))
        computeMissingAIMasks()
        computeMissingInpaints()
    }

    func reset(_ key: ParamKey) {
        set(key, nil)
    }

    func reset(group: PasteGroup) {
        clearPresetPreview()
        for key in group.keys { recipe.set(key, nil, at: app.clock.now()) }
        pushHistory(label: "Reset \(group.displayName)")
    }

    func resetAll() {
        clearPresetPreview()
        recipe.resetAll(at: app.clock.now())
        pushHistory(label: "Reset all")
    }

    /// Changes the recipe directly. Live changes (no label) skip history; call
    /// `pushHistory` when the gesture ends.
    func updateRecipe(_ label: String? = nil, _ mutate: (inout Recipe, HLCStamp) -> Void) {
        clearPresetPreview()
        if label == nil { noteInteraction() }
        var copy = recipe
        mutate(&copy, app.clock.now())
        recipe = copy
        if let label { pushHistory(label: label) }
    }

    func requestRender() { render() }

    func pushHistory(label: String) {
        guard history.indices.contains(historyIndex), history[historyIndex].recipe != recipe else { return }
        history.removeSubrange((historyIndex + 1)...)
        history.append(Step(label: label, recipe: recipe))
        historyIndex = history.count - 1
        saveDraft()
    }

    /// Keeps unsaved edits on disk, so a crash or a killed app doesn't lose them.
    private func saveDraft() {
        let recipe = self.recipe, id = asset.id, previous = draftWrite
        draftWrite = Task.detached(priority: .utility) {
            await previous?.value  // In order, so an older write never lands last.
            if recipe.params.isEmpty { RecipeDrafts.shared.clear(for: id) } else { RecipeDrafts.shared.save(recipe, for: id) }
        }
    }

    func undo() {
        guard canUndo else { return }
        let undone = history[historyIndex].label
        clearPresetPreview()
        historyIndex -= 1
        recipe = history[historyIndex].recipe
        saveDraft()
        showHistoryNotice("Undo: \(undone)")
    }

    func redo() {
        guard canRedo else { return }
        clearPresetPreview()
        historyIndex += 1
        recipe = history[historyIndex].recipe
        saveDraft()
        showHistoryNotice("Redo: \(history[historyIndex].label)")
    }

    /// Names the step undo or redo changed, on the photo where it's seen.
    private func showHistoryNotice(_ text: String) {
        historyNotice = text
        historyNoticeTask?.cancel()
        historyNoticeTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { historyNotice = nil }
        }
    }

    // MARK: Back to when opened

    /// The recipe when this photo was opened.
    var openedRecipe: Recipe? { history.first?.recipe }

    /// Whether the photo had edits in `group` when it was opened, and they've changed since.
    func canReturnToOpened(_ group: PasteGroup) -> Bool {
        guard let opened = openedRecipe, opened.hasEdits(in: group) else { return false }
        return group.keys.contains { recipe[$0] != opened[$0] }
    }

    var canReturnToOpened: Bool { openedRecipe.map { $0.params != recipe.params } ?? false }

    /// Puts `group` (or everything) back the way it was when the photo was opened,
    /// as one undoable step.
    func returnToOpened(_ group: PasteGroup? = nil) {
        guard let opened = openedRecipe else { return }
        clearPresetPreview()
        let now = app.clock.now()
        let keys = group.map { Set($0.keys) } ?? Set(recipe.params.keys).union(opened.params.keys)
        for key in keys where recipe[key] != opened[key] { recipe.set(key, opened[key], at: now) }
        pushHistory(label: group.map { "\($0.displayName) back to when opened" } ?? "Back to when opened")
    }

    func jump(to step: Step) {
        if let index = history.firstIndex(of: step) {
            historyIndex = index
            recipe = step.recipe
            saveDraft()
        } else {
            recipe = step.recipe
            pushHistory(label: "Snapshot “\(step.label)”")
        }
    }

    func takeSnapshot() {
        snapshots.insert(Step(label: "Snapshot \(snapshots.count + 1)", recipe: recipe), at: 0)
    }

    static func label(for key: ParamKey, in recipe: Recipe, defaults: PhotoDefaults) -> String {
        guard let spec = ParamCatalog.spec(for: key) else { return key.rawValue }
        guard let value = recipe[key] else { return "\(spec.label) reset" }
        switch value {
        case .scalar(let number): return "\(spec.label) \(ValueFormat.format(key, number, defaults: defaults))"
        default: return spec.label
        }
    }

    /// Lightroom-style Auto: sets the six Light sliders from the photo's histogram,
    /// measured after white balance.
    func autoTone() {
        guard let decoded = base else { return }
        clearPresetPreview()
        var wbOnly = Recipe()
        let stamp = HLCStamp(millis: 0, node: "auto")
        for key in [ParamKey.temperature, .tint] { if let value = recipe[key] { wbOnly.set(key, value, at: stamp) } }
        let measured = GradeGraph.apply(wbOnly, to: decoded.image, inputs: GradeInputs(defaults: defaults))
        let values = AutoTone.values(for: measured)
        for key in [ParamKey.exposure, .contrast, .highlights, .shadows, .whites, .blacks] {
            recipe.set(key, values[key].map { .scalar($0) }, at: app.clock.now())
        }
        pushHistory(label: "Auto tone")
    }

    /// The Fujifilm preset matching the film simulation the photo was shot with.
    var cameraFilmSimulation: Preset? {
        info?.filmSimulation.flatMap(FilmSimulations.preset(named:))
    }

    // MARK: Copy, paste, presets

    func copyEdits() {
        app.copy(recipe, from: filename, defaults: defaults)
    }

    func paste(_ clip: RecipeClip, groups: Set<PasteGroup>, mode: PasteMode) {
        clearPresetPreview()
        recipe = recipe.pasting(clip, groups: groups, mode: mode, targetDefaults: defaults, stamp: app.clock.now())
        pushHistory(label: "Paste from \(clip.sourceName)")
        resolveAutoStraighten()
    }

    func matchPrevious() {
        guard let clip = app.previousEdit else { return }
        paste(clip, groups: PasteGroup.defaultSelection, mode: .set)
    }

    func apply(_ preset: Preset?) {
        let base = presetBase ?? recipe
        guard let preset else {
            recipe = base
            clearPresetPreview()
            pushHistory(label: "Original")
            return
        }
        presetBase = base
        activePreset = preset
        presetAmount = 1
        recipe = base.applying(preset, amount: 1, defaults: defaults, stamp: app.clock.now())
        pushHistory(label: "Preset “\(preset.name)”")
        computeMissingAIMasks()
    }

    func setPresetAmount(_ amount: Double, commit: Bool) {
        guard let preset = activePreset, let presetBase else { return }
        presetAmount = amount
        recipe = presetBase.applying(preset, amount: amount, defaults: defaults, stamp: app.clock.now())
        if commit { pushHistory(label: "\(preset.name) \(Int(amount * 100))%") }
    }

    private func clearPresetPreview() {
        activePreset = nil
        presetBase = nil
    }

    /// A small render of this photo with a preset applied, for preset tiles.
    func presetThumbnail(_ preset: Preset?) async -> SendableImage? {
        guard let decoded = base else { return nil }
        let start = presetBase ?? recipe
        let recipe = preset.map { start.applying($0, amount: 1, defaults: defaults, stamp: HLCStamp(millis: 0, node: "tile")) } ?? start
        let inputs = GradeInputs(defaults: defaults, luts: app.lutStore, aiMasks: aiStore)
        let box = UncheckedImage(decoded.image)
        return await Task.detached(priority: .userInitiated) {
            ThumbnailRenderer.render(recipe, base: box.image, inputs: inputs, longEdge: 240).map(SendableImage.init)
        }.value
    }

    // MARK: Crop

    var crop: CropGeometry {
        if case .crop(let geometry)? = recipe[.crop] { return geometry }
        return CropGeometry()
    }

    func setCropLive(_ geometry: CropGeometry) { setLive(.crop, .crop(geometry)) }
    func commitCrop() { commit(.crop) }

    /// Aspect ratio of the straightened, uncropped frame, from the decoded image.
    var frameAspect: Double {
        guard let size = base?.size, size.height > 0 else { return 3 / 2 }
        return size.width / size.height
    }

    // MARK: Auto straighten

    private(set) var isLeveling = false

    /// Levels the photo: the camera's level reading when the file has one, else
    /// Apple's horizon detection. The slider then fine-tunes from there.
    func autoStraighten() {
        guard let session, let decoded = base, !isLeveling else { return }
        isLeveling = true
        let source = session.original
        let image = UncheckedImage(decoded.image)
        let task = app.jobs.run("Finding the level", detail: filename) { _ in
            await AutoStraightener.detect(source: source, image: image.image).map { LevelResult(method: $0.0, angle: $0.1) }
        }
        Task {
            defer { isLeveling = false }
            guard let found = try? await task.value else {
                app.showToast("No tilted horizon found")
                return
            }
            var geometry = crop
            geometry.auto = AutoStraighten(method: found.method, detected: found.angle)
            geometry.angle = found.angle
            updateRecipe(String(format: "Auto straighten %+.1f° (%@)", found.angle, found.method.displayName.lowercased())) { recipe, stamp in
                recipe.set(.crop, .crop(geometry), at: stamp)
            }
        }
    }

    private struct LevelResult: Sendable {
        var method: AutoStraighten.Method
        var angle: Double
    }

    /// After a paste, auto straighten is found again for this photo.
    func resolveAutoStraighten() {
        guard let session, let decoded = base, crop.auto?.isResolved == false else { return }
        let source = session.original
        let image = UncheckedImage(decoded.image)
        let recipe = self.recipe
        let stamp = app.clock.now()
        let task = app.jobs.run("Finding the level", detail: filename) { _ in
            await AutoStraightener.resolve(recipe, source: source, image: image.image, stamp: stamp)
        }
        Task {
            guard let resolved = try? await task.value, case .crop(let geometry)? = resolved[.crop] else { return }
            updateRecipe(geometry.auto?.method.map { "Auto straighten (\($0.displayName.lowercased()))" } ?? "Straighten") { recipe, stamp in
                recipe.set(.crop, .crop(geometry), at: stamp)
            }
        }
    }

    // MARK: Saving and export

    /// Saves to the library if anything changed. Runs as a job; safe to call when leaving.
    func saveIfNeeded() {
        guard let session, isDirty else { return }
        let recipe = self.recipe
        let library = app.library
        let luts = app.lutStore
        savedParams = recipe.params
        if let info { app.previousEdit = RecipeClip(recipe: recipe, sourceName: filename, sourceDefaults: info.defaults) }
        let app = self.app
        let background = BackgroundActivity.begin("Saving edit")
        let filename = self.filename
        let remote = app.remoteLibrary, lutFiles = recipe.lutFiles(from: luts)
        app.jobs.run("Saving edit to \(library.displayName)", detail: filename, photos: 1) { reporter in
            defer { background.end() }
            if let remote {
                // The device with the original renders the full-size image and saves it.
                try await remote.saveEdit(session, recipe: recipe, luts: lutFiles) { fraction, detail in
                    reporter.progress(fraction.map { $0 * 0.95 }, detail: detail.map { "\(filename) · \($0)" } ?? filename)
                }
                RecipeDrafts.shared.clear(for: session.asset.id, ifMatching: recipe)
                return
            }
            let data = try await Exporter.render(
                source: session.original, recipe: recipe, luts: luts, options: ExportOptions(format: .heic),
                queued: { reporter.progress(nil, detail: "\(filename) · waiting for earlier saves") }
            ) {
                reporter.progress($0 * 0.9, detail: filename)
            }
            try await library.save(session, recipe: recipe, rendered: data, format: .heic)
            RecipeDrafts.shared.clear(for: session.asset.id, ifMatching: recipe)
            await MainActor.run { app.pendingThumbnails[session.asset.id] = nil }
        }
    }

    func revertToOriginal() {
        guard let session else { return }
        let library = app.library
        app.jobs.run("Reverting", detail: filename) { _ in try await library.revert(session.asset) }
        recipe.resetAll(at: app.clock.now())
        savedParams = recipe.params
        RecipeDrafts.shared.clear(for: asset.id)
        foreignEdit = nil
        pushHistory(label: "Revert to original")
    }

    func export(_ options: ExportOptions) -> Task<URL, any Error>? {
        guard let session else { return nil }
        let recipe = self.recipe
        let luts = app.lutStore
        let baseName = (filename as NSString).deletingPathExtension
        let remote = app.remoteLibrary, lutFiles = recipe.lutFiles(from: luts)
        return app.jobs.run("Exporting \(options.format.displayName) to share", detail: filename) { reporter in
            if let remote {
                return try await remote.export(session, recipe: recipe, options: options, luts: lutFiles) { fraction, _ in reporter.progress(fraction) }
            }
            return try await Exporter.renderToFile(source: session.original, recipe: recipe, luts: luts, options: options, baseName: baseName) {
                reporter.progress($0)
            }
        }
    }

    /// Renders an export and adds it to the library as a new photo, as one job.
    func saveExportToLibrary(_ options: ExportOptions) {
        guard let session else { return }
        let recipe = self.recipe
        let luts = app.lutStore
        let library = app.library
        let baseName = (filename as NSString).deletingPathExtension
        let background = BackgroundActivity.begin("Exporting")
        let remote = app.remoteLibrary, lutFiles = recipe.lutFiles(from: luts)
        app.jobs.run("Exporting \(options.format.displayName) to \(library.displayName)", detail: filename, photos: 1) { reporter in
            defer { background.end() }
            if let remote {
                try await remote.exportToLibrary(session, recipe: recipe, options: options, luts: lutFiles) { fraction, _ in reporter.progress(fraction) }
                return
            }
            let url = try await Exporter.renderToFile(source: session.original, recipe: recipe, luts: luts, options: options, baseName: baseName) {
                reporter.progress($0 * 0.9)
            }
            try await library.addPhoto(fileAt: url)
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The size a full-size export comes out at: the original, cropped.
    var exportFullSize: CGSize? {
        guard let native = info?.nativeSize, native.width > 0, native.height > 0 else { return nil }
        let rect = crop.rect
        return CGSize(width: (native.width * rect.width).rounded(), height: (native.height * rect.height).rounded())
    }

    /// Encodes a small render of the current edit, to estimate export file sizes.
    func exportSample(format: ExportFormat, quality: Double) async -> (bytes: Int, pixels: Double)? {
        guard let decoded = base else { return nil }
        let recipe = self.recipe
        var inputs = GradeInputs(defaults: defaults, luts: app.lutStore, aiMasks: aiStore)
        inputs.inpaints = inpaintStore
        let box = UncheckedImage(decoded.image)
        return await Task.detached(priority: .utility) {
            let image = box.image
            let scale = min(1, 1024 / max(image.extent.width, image.extent.height))
            let graded = GradeGraph.apply(recipe, to: image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), inputs: inputs)
            guard let bytes = ExportSizing.sampleBytes(graded, format: format, quality: quality) else { return nil }
            return (bytes, Double(graded.extent.width * graded.extent.height))
        }.value
    }

    func close() {
        decodeTask?.cancel()
        redecodeDebounce?.cancel()
        saveIfNeeded()
    }
}

/// CIImage is immutable and thread-safe.
struct UncheckedImage: @unchecked Sendable {
    let image: CIImage
    init(_ image: CIImage) { self.image = image }
}
