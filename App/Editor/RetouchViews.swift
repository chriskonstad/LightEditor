import EditorCore
import SwiftUI

/// Tools shown while retouching: Remove, Heal or Clone, brush size and the selected spot.
struct RetouchTools: View {
    @Bindable var model: EditorModel
    var onDone: () -> Void
    @AppStorage(DiffusionTerms.defaultsKey) private var diffusionAccepted = false
    /// The engine choice waiting for the diffusion license to be accepted.
    @State private var pendingDiffusion: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Tool", selection: $model.retouchKind) {
                ForEach(RetouchSpot.Kind.allCases) { kind in
                    Label(kind.displayName, systemImage: kind.systemImage).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("retouch.tool")
            Text(hint)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Brush size").foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(Int((model.retouchBrushSize * 1000).rounded()))").valueStyle()
                }
                .font(.subheadline)
                FineSlider(
                    position: (model.retouchBrushSize - 0.005) / 0.145,
                    onChange: { model.retouchBrushSize = 0.005 + $0 * 0.145 },
                    onReset: { model.retouchBrushSize = 0.03 }
                )
                .accessibilityLabel("Brush size")
            }

            if model.retouchKind == .remove, model.selectedSpot?.kind != .remove {
                engineMenu(title: "New removals", selection: model.removeEngine) { model.removeEngine = $0 }
            }

            if let spot = model.selectedSpot {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Image(systemName: spot.kind.systemImage)
                        Picker("Spot", selection: Binding(get: { spot.kind }, set: { model.setSpotKind(spot.id, $0) })) {
                            ForEach(RetouchSpot.Kind.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        Button("Delete", systemImage: "trash", role: .destructive) { model.deleteSpot(spot.id) }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("retouch.delete")
                    }
                    if spot.kind == .remove {
                        HStack {
                            engineMenu(title: "Filled with", selection: spot.engine) { model.setSpotEngine(spot.id, $0) }
                            if spot.engine == .diffusion {
                                Spacer()
                                Button("Try another", systemImage: "arrow.trianglehead.2.clockwise") { model.tryAnotherFill(spot.id) }
                                    .font(.subheadline)
                                    .disabled(model.inpainting.contains(spot.id))
                                    .accessibilityIdentifier("retouch.tryAnother")
                            }
                        }
                    }
                    if let status = model.spotStatus(spot) {
                        HStack(spacing: 6) {
                            if model.inpainting.contains(spot.id) { ProgressView().controlSize(.small) }
                            Text(status).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        }
                        .accessibilityIdentifier("retouch.status")
                    }
                }
                .font(.subheadline)
            }

            HStack {
                Toggle("Show spots", isOn: $model.showSpots)
                    .toggleStyle(.button)
                    .font(.subheadline)
                Text("\(model.retouches.count) spot\(model.retouches.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Clear all") { model.clearRetouches() }
                    .disabled(model.retouches.isEmpty)
                Button("Done", action: onDone)
                    .buttonStyle(AccentButtonStyle())
                    .accessibilityIdentifier("retouch.done")
            }
        }
        .sheet(isPresented: Binding(get: { pendingDiffusion != nil }, set: { if !$0 { pendingDiffusion = nil } })) {
            DiffusionTermsSheet { pendingDiffusion?() }
        }
    }

    /// Picks how Remove fills: LaMa at full resolution, fast LaMa, or diffusion.
    private func engineMenu(title: String?, selection: RemoveEngine, set: @escaping (RemoveEngine) -> Void) -> some View {
        Menu {
            ForEach(RemoveEngine.allCases) { engine in
                let available = engine != .diffusion || DiffusionInpainter.shared.isAvailable
                Button {
                    if engine == .diffusion && !diffusionAccepted {
                        pendingDiffusion = { set(engine) }
                    } else {
                        set(engine)
                    }
                } label: {
                    if engine == selection {
                        Label(engine.displayName, systemImage: "checkmark")
                    } else {
                        Text(engine.displayName)
                    }
                    Text(available ? engine.detail : "Not in this build yet.")
                }
                .disabled(!available)
            }
        } label: {
            HStack(spacing: 4) {
                if let title { Text(title + ":").foregroundStyle(Theme.textSecondary) }
                Text(selection.displayName)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.subheadline)
        }
        .accessibilityIdentifier("retouch.engine")
    }

    private var hint: String {
        switch model.retouchKind {
        case .remove:
            Inpainter.shared.isAvailable
                ? "Paint over what to remove. AI fills it from the surroundings, on this device."
                : "AI removal isn't in this build. Run scripts/fetch-models.sh, then rebuild."
        case .heal: "Paint over a blemish. Texture comes from a nearby area, matched to the spot's tone. Drag the dashed circle to change the source."
        case .clone: "Paint over an area to copy another part of the photo onto it. Drag the dashed circle to change the source."
        }
    }
}

/// On-photo retouch: paint spots, tap to select, drag a heal or clone source.
struct RetouchCanvasOverlay: View {
    let model: EditorModel
    let viewSize: CGSize
    @State private var sourceDragStart: NormalizedPoint?
    @State private var brushCursor: CGPoint?
    @State private var paintStart: CGPoint?
    @State private var zoomStart: (rect: CGRect, scale: Double, center: CGPoint)?
    @Environment(\.displayScale) private var displayScale

    /// The photo on screen, following zoom and pan.
    private var frame: CGRect { model.photoFrame(in: viewSize) }

    private var longEdge: CGFloat { max(frame.width, frame.height) }

    /// How much bigger than Fit the photo is on screen.
    private var zoomFactor: CGFloat { longEdge / max(model.fitLongEdge(in: viewSize), 1) }

    private func normalized(_ point: CGPoint) -> NormalizedPoint {
        NormalizedPoint(x: min(max((point.x - frame.minX) / frame.width, 0), 1), y: min(max((point.y - frame.minY) / frame.height, 0), 1))
    }

    private func viewPoint(_ point: NormalizedPoint) -> CGPoint {
        CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
    }

    private func viewRect(_ rect: NormalizedRect, offset: NormalizedPoint = NormalizedPoint(x: 0, y: 0)) -> CGRect {
        CGRect(x: frame.minX + (rect.x + offset.x) * frame.width, y: frame.minY + (rect.y + offset.y) * frame.height,
               width: rect.width * frame.width, height: rect.height * frame.height)
    }

    var body: some View {
        ZStack {
            input
                .accessibilityLabel("Paint to retouch. Pinch or drag with two fingers to zoom and move.")
                .accessibilityIdentifier("retouch.canvas")

            if model.showSpots {
                ForEach(model.retouches) { spot in
                    let selected = spot.id == model.selectedSpotID
                    Ellipse()
                        .stroke(selected ? Theme.accent : .white.opacity(0.7), lineWidth: selected ? 2 : 1)
                        .frame(width: viewRect(spot.bounds).width, height: viewRect(spot.bounds).height)
                        .position(x: viewRect(spot.bounds).midX, y: viewRect(spot.bounds).midY)
                        .overlay {
                            if model.inpainting.contains(spot.id) {
                                ProgressView().controlSize(.small)
                                    .position(x: viewRect(spot.bounds).midX, y: viewRect(spot.bounds).midY)
                            }
                        }
                        .allowsHitTesting(false)
                }
            }

            if let spot = model.selectedSpot, spot.kind.needsSource, let offset = spot.sourceOffset {
                sourceHandle(spot: spot, offset: offset)
            }

            if let stroke = model.paintingStroke {
                Path { path in
                    let points = stroke.points.map(viewPoint)
                    path.addLines(points)
                }
                .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: stroke.radius * 2 * longEdge, lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
            }
            if let brushCursor {
                Circle()
                    .strokeBorder(.white, lineWidth: 1.5)
                    // Same size on screen at any zoom.
                    .frame(width: model.retouchBrushSize * 2 * model.fitLongEdge(in: viewSize),
                           height: model.retouchBrushSize * 2 * model.fitLongEdge(in: viewSize))
                    .position(brushCursor)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
    }

    // MARK: Input

    @ViewBuilder
    private var input: some View {
        #if os(iOS)
        CanvasInput(handlers: CanvasInputHandlers(
            paintBegan: { point in
                paintStart = point
                brushCursor = point
                model.beginRetouchStroke(at: normalized(point), zoomFactor: zoomFactor)
            },
            paintMoved: { point in
                brushCursor = point
                model.extendRetouchStroke(to: normalized(point))
            },
            paintEnded: { point in
                brushCursor = nil
                paintStart = nil
                model.endRetouchStroke()
            },
            paintCancelled: {
                brushCursor = nil
                paintStart = nil
                model.cancelRetouchStroke()
            },
            tapped: { point in
                // Tap a spot to select it; elsewhere, a tap paints a dot.
                if !selectSpot(at: point) {
                    model.beginRetouchStroke(at: normalized(point), zoomFactor: zoomFactor)
                    model.endRetouchStroke()
                }
            },
            zoomBegan: { center in
                let drawable = model.renderer.lastDrawableSize
                zoomStart = (model.renderer.imageRect(in: drawable), model.zoomScale(drawableSize: drawable),
                             CGPoint(x: center.x * displayScale, y: center.y * displayScale))
            },
            zoomChanged: { scale, center in
                guard let start = zoomStart else { return }
                let drawable = model.renderer.lastDrawableSize
                let now = CGPoint(x: center.x * displayScale, y: center.y * displayScale)
                // Move the photo with the fingers, then scale it around them: a pinch
                // zooms, a two-finger drag (scale 1) pans.
                let moved = CGRect(x: start.rect.minX + now.x - start.center.x, y: start.rect.minY + now.y - start.center.y,
                                   width: start.rect.width, height: start.rect.height)
                model.zoom(to: start.scale * scale, anchor: now, from: moved, startScale: start.scale, drawableSize: drawable)
            },
            zoomEnded: { zoomStart = nil }
        ))
        #else
        Color.clear
            .contentShape(Rectangle())
            .gesture(paintGesture)
            .simultaneousGesture(magnifyGesture)
        #endif
    }

    /// Selects the topmost spot under `point`, if any.
    private func selectSpot(at point: CGPoint) -> Bool {
        let tapped = normalized(point)
        guard let hit = model.retouches.last(where: { spot in
            let b = spot.bounds
            return tapped.x >= b.x && tapped.x <= b.x + b.width && tapped.y >= b.y && tapped.y <= b.y + b.height
        }) else { return false }
        model.cancelRetouchStroke()
        model.selectedSpotID = hit.id
        return true
    }

    #if os(macOS)
    /// Paint a new spot, or click an existing one to select it.
    private var paintGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                brushCursor = drag.location
                if model.paintingStroke == nil { model.beginRetouchStroke(at: normalized(drag.startLocation), zoomFactor: zoomFactor) }
                model.extendRetouchStroke(to: normalized(drag.location))
            }
            .onEnded { drag in
                brushCursor = nil
                if hypot(drag.translation.width, drag.translation.height) < 4, selectSpot(at: drag.startLocation) { return }
                model.endRetouchStroke()
            }
    }

    /// Trackpad pinch to zoom around the pointer.
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                model.cancelRetouchStroke()
                let drawable = model.renderer.lastDrawableSize
                if zoomStart == nil {
                    zoomStart = (model.renderer.imageRect(in: drawable), model.zoomScale(drawableSize: drawable),
                                 CGPoint(x: value.startLocation.x * displayScale, y: value.startLocation.y * displayScale))
                }
                guard let start = zoomStart else { return }
                model.zoom(to: start.scale * value.magnification, anchor: start.center, from: start.rect, startScale: start.scale, drawableSize: drawable)
            }
            .onEnded { _ in zoomStart = nil }
    }
    #endif

    /// The dashed source circle with a line to the spot; drag to move the source.
    private func sourceHandle(spot: RetouchSpot, offset: NormalizedPoint) -> some View {
        let target = viewRect(spot.bounds)
        let source = viewRect(spot.bounds, offset: offset)
        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: target.midX, y: target.midY))
                path.addLine(to: CGPoint(x: source.midX, y: source.midY))
            }
            .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .allowsHitTesting(false)
            Ellipse()
                .strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .background(Ellipse().fill(.white.opacity(0.08)))
                .frame(width: max(source.width, Theme.minTouch), height: max(source.height, Theme.minTouch))
                .contentShape(Ellipse())
                .position(x: source.midX, y: source.midY)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let start = sourceDragStart ?? offset
                            if sourceDragStart == nil { sourceDragStart = offset }
                            let moved = NormalizedPoint(x: start.x + drag.translation.width / frame.width, y: start.y + drag.translation.height / frame.height)
                            model.moveSpotSource(spot.id, to: moved, commit: false)
                        }
                        .onEnded { _ in
                            sourceDragStart = nil
                            if let offset = model.selectedSpot?.sourceOffset { model.moveSpotSource(spot.id, to: offset, commit: true) }
                        }
                )
                .accessibilityLabel("Source area")
                .accessibilityIdentifier("retouch.source")
        }
    }
}
