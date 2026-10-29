import EditorCore
import MetalKit
import SwiftUI

/// Hosts the EDR `MTKView` the preview renderer draws into.
struct MetalPreview {
    let renderer: PreviewRenderer
}

#if os(macOS)
extension MetalPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        renderer.attach(to: view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        // A new photo brings a new renderer; the view itself is reused.
        if view.delegate !== renderer { renderer.attach(to: view) }
    }
}
#else
extension MetalPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.isUserInteractionEnabled = false
        renderer.attach(to: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        // A new photo brings a new renderer; the view itself is reused.
        if view.delegate !== renderer { renderer.attach(to: view) }
    }
}
#endif

/// The photo with its overlays: histogram, camera badge, compare toggle and the
/// crop overlay. Pinch or double-tap to zoom to 100%.
struct PhotoCanvas: View {
    @Bindable var model: EditorModel
    var showOverlays = true
    @Environment(\.displayScale) private var displayScale
    @State private var panStart: CGPoint?
    @State private var pinchStart: (rect: CGRect, scale: Double)?
    @State private var zoomLabel: String?
    @State private var zoomLabelTask: Task<Void, Never>?
    @State private var compareHold: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.ground
                MetalPreview(renderer: model.renderer)
                    .accessibilityLabel("Photo")
                    .accessibilityIdentifier("photoCanvas")

                if model.isCropping, model.phase == .ready {
                    CropOverlay(model: model, viewSize: proxy.size)
                }

                if model.isEditingMasks, model.phase == .ready {
                    MaskCanvasOverlay(model: model, viewSize: proxy.size)
                }

                if model.isRetouching, model.phase == .ready {
                    RetouchCanvasOverlay(model: model, viewSize: proxy.size)
                }

                if showOverlays {
                    overlays
                }

                if model.showsSplit, model.phase == .ready {
                    SplitDivider(model: model, viewSize: proxy.size)
                }

                if let notice = model.historyNotice {
                    Label(notice, systemImage: notice.hasPrefix("Undo") ? "arrow.uturn.backward" : "arrow.uturn.forward")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .accessibilityIdentifier("historyNotice")
                }

                if let label = model.compare ? "Before" : model.hiddenLabel {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 10)
                        .accessibilityIdentifier("beforeBadge")
                }

                if case .failed(let message) = model.phase {
                    ContentUnavailableView("Couldn't open photo", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
            .contentShape(Rectangle())
            .gesture(panGesture(size: proxy.size), including: model.isCropping || model.showsOriginalFrame ? .subviews : .all)
            .simultaneousGesture(pinchGesture, including: model.isCropping || model.showsOriginalFrame ? .subviews : .all)
            .onTapGesture(count: 2) { toggleZoom() }
            .overlay(alignment: .center) {
                if let zoomLabel {
                    Text(zoomLabel)
                        .font(.headline.monospacedDigit())
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(Theme.textPrimary)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .accessibilityIdentifier("zoomLabel")
                }
            }
            .animation(.easeOut(duration: 0.15), value: zoomLabel)
        }
        .clipped()
    }

    private var overlays: some View {
        ZStack {
            HistogramView(histogram: model.histogram)
                .frame(width: 96, height: 48)
                .padding(6)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(10)

            if model.app.remote.reconnecting, let host = model.app.remote.connectedHost {
                Label("Reconnecting to \(host) · edits are kept", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
                    .accessibilityIdentifier("reconnectingBadge")
            }

            if !model.badge.isEmpty {
                Text(model.badge)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(10)
                    .accessibilityIdentifier("decoderBadge")
            }

            // Tap for the split before/after; press and hold to see the whole photo before.
            Image(systemName: "square.split.2x1")
                .font(.body.weight(.medium))
                .frame(width: Theme.minTouch, height: Theme.minTouch)
                .background(model.splitView || model.compare ? Theme.accent : .black.opacity(0.5), in: Circle())
                .foregroundStyle(model.splitView || model.compare ? Theme.onAccent : Theme.textPrimary)
                .contentShape(Circle())
                .gesture(compareGesture)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(8)
                .accessibilityElement()
                .accessibilityLabel("Before and after")
                .accessibilityHint("Shows a split before and after. Press and hold to see the whole photo before.")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.splitView.toggle() }
                .accessibilityIdentifier("compareToggle")
        }
    }

    /// Tap toggles the split; holding past 0.3 s shows the whole photo before until release.
    private var compareGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard compareHold == nil else { return }
                compareHold = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    if !Task.isCancelled { model.compare = true }
                }
            }
            .onEnded { _ in
                compareHold?.cancel()
                compareHold = nil
                if model.compare { model.compare = false } else { model.splitView.toggle() }
            }
    }

    private func toggleZoom() {
        guard !model.isCropping, !model.showsOriginalFrame else { return }
        if case .fit = model.zoom { model.zoom = .actual(scale: 1) } else { model.zoom = .fit }
        showZoomLabel()
    }

    /// Shows the zoom percentage while zooming and briefly after.
    private func showZoomLabel() {
        let percent = Int((model.zoomScale(drawableSize: model.renderer.lastDrawableSize) * 100).rounded())
        zoomLabel = model.zoom == .fit ? "Fit · \(percent)%" : "\(percent)%"
        zoomLabelTask?.cancel()
        zoomLabelTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            zoomLabel = nil
        }
    }

    /// Pinch to any zoom between Fit and 800%, anchored under the fingers.
    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !model.isCropping, !model.showsOriginalFrame else { return }
                let drawable = model.renderer.lastDrawableSize
                if pinchStart == nil {
                    pinchStart = (model.renderer.imageRect(in: drawable), model.zoomScale(drawableSize: drawable))
                }
                guard let start = pinchStart else { return }
                let anchor = CGPoint(x: value.startLocation.x * displayScale, y: value.startLocation.y * displayScale)
                model.zoom(to: start.scale * value.magnification, anchor: anchor, from: start.rect, startScale: start.scale, drawableSize: drawable)
                showZoomLabel()
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func panGesture(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { drag in
                guard case .actual = model.zoom, pinchStart == nil else { return }
                let start = panStart ?? model.pan
                if panStart == nil { panStart = start }
                model.pan = CGPoint(x: start.x + drag.translation.width * displayScale, y: start.y + drag.translation.height * displayScale)
            }
            .onEnded { _ in panStart = nil }
    }
}

/// Crop rectangle with corner handles over the straightened, uncropped frame.
struct CropOverlay: View {
    let model: EditorModel
    let viewSize: CGSize
    @State private var startRect: NormalizedRect?

    /// The image's rect in view points (aspect-fit, like the renderer).
    private var frame: CGRect {
        let aspect = model.frameAspect
        var width = viewSize.width, height = width / aspect
        if height > viewSize.height { height = viewSize.height; width = height * aspect }
        return CGRect(x: (viewSize.width - width) / 2, y: (viewSize.height - height) / 2, width: width, height: height)
    }

    var body: some View {
        let frame = self.frame
        let rect = model.crop.rect
        let crop = CGRect(x: frame.minX + rect.x * frame.width, y: frame.minY + rect.y * frame.height, width: rect.width * frame.width, height: rect.height * frame.height)
        ZStack {
            // Dim everything outside the crop with four bands.
            Path { path in
                path.addRect(CGRect(x: 0, y: 0, width: viewSize.width, height: crop.minY))
                path.addRect(CGRect(x: 0, y: crop.maxY, width: viewSize.width, height: viewSize.height - crop.maxY))
                path.addRect(CGRect(x: 0, y: crop.minY, width: crop.minX, height: crop.height))
                path.addRect(CGRect(x: crop.maxX, y: crop.minY, width: viewSize.width - crop.maxX, height: crop.height))
            }
            .fill(.black.opacity(0.6))
            .allowsHitTesting(false)

            // A fine square grid for leveling against, with the thirds on top.
            Path { path in
                let step = max(min(crop.width, crop.height) / 8, 12)
                var x = crop.minX + step
                while x < crop.maxX - 1 {
                    path.move(to: CGPoint(x: x, y: crop.minY)); path.addLine(to: CGPoint(x: x, y: crop.maxY))
                    x += step
                }
                var y = crop.minY + step
                while y < crop.maxY - 1 {
                    path.move(to: CGPoint(x: crop.minX, y: y)); path.addLine(to: CGPoint(x: crop.maxX, y: y))
                    y += step
                }
            }
            .stroke(.white.opacity(0.16), lineWidth: 0.5)
            .allowsHitTesting(false)

            Path { path in
                for i in 1..<3 {
                    let fx = crop.minX + crop.width * CGFloat(i) / 3, fy = crop.minY + crop.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: fx, y: crop.minY)); path.addLine(to: CGPoint(x: fx, y: crop.maxY))
                    path.move(to: CGPoint(x: crop.minX, y: fy)); path.addLine(to: CGPoint(x: crop.maxX, y: fy))
                }
            }
            .stroke(.white.opacity(0.45), lineWidth: 0.75)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(.white, lineWidth: 1.5)
                .frame(width: crop.width, height: crop.height)
                .position(x: crop.midX, y: crop.midY)
                .contentShape(Rectangle())
                .gesture(drag(frame: frame) { start, dx, dy in CropMath.move(start, dx: dx, dy: dy) })
                .accessibilityIdentifier("cropRect")

            ForEach(Corner.allCases, id: \.self) { corner in
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .frame(width: Theme.minTouch, height: Theme.minTouch)
                    .contentShape(Rectangle())
                    .position(corner.point(in: crop))
                    .gesture(drag(frame: frame) { start, dx, dy in resize(start, corner: corner, dx: dx, dy: dy) })
                    .accessibilityIdentifier("cropHandle.\(corner)")
            }
        }
    }

    typealias Corner = CropMath.Corner


    private func drag(frame: CGRect, update: @escaping (NormalizedRect, Double, Double) -> NormalizedRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let start = startRect ?? model.crop.rect
                if startRect == nil { startRect = start }
                var geometry = model.crop
                geometry.rect = update(start, drag.translation.width / frame.width, drag.translation.height / frame.height)
                model.setCropLive(geometry)
            }
            .onEnded { _ in
                startRect = nil
                model.commitCrop()
            }
    }

    private func resize(_ start: NormalizedRect, corner: Corner, dx: Double, dy: Double) -> NormalizedRect {
        CropMath.resize(start, dragging: corner, dx: dx, dy: dy, aspect: model.crop.aspect?.value, frameAspect: model.frameAspect)
    }
}

/// The draggable before/after divider for split view. It sits at a fraction of
/// the view's width, so it stays put while the photo zooms and pans under it.
struct SplitDivider: View {
    let model: EditorModel
    let viewSize: CGSize

    /// The photo's on-screen rect at Fit; zoomed in, the photo fills the view.
    private var photoRect: CGRect {
        let size = model.displayedImageSize
        guard case .fit = model.zoom, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: viewSize) }
        let scale = min(viewSize.width / size.width, viewSize.height / size.height)
        return CGRect(
            x: (viewSize.width - size.width * scale) / 2, y: (viewSize.height - size.height * scale) / 2,
            width: size.width * scale, height: size.height * scale
        )
    }

    var body: some View {
        let rect = photoRect
        let x = viewSize.width * model.splitPosition
        ZStack {
            Rectangle()
                .fill(.white)
                .allowsHitTesting(false)
                .frame(width: 2, height: rect.height)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .position(x: x, y: rect.midY)
            Image(systemName: "chevron.left.chevron.right")
                .font(.caption.weight(.bold))
                .frame(width: 34, height: 34)
                .background(.white, in: Circle())
                .foregroundStyle(.black)
                .shadow(radius: 3)
                .position(x: x, y: rect.midY)
            label("Before").position(x: max(rect.minX, 0) + 36, y: max(rect.minY, 0) + 16)
            label("After").position(x: min(rect.maxX, viewSize.width) - 32, y: max(rect.minY, 0) + 16)
            // Only a strip around the line takes touches, so the rest of the
            // photo still pans, pinches and double-taps to zoom.
            Color.clear
                .frame(width: Theme.minTouch, height: rect.height)
                .contentShape(Rectangle())
                .position(x: x, y: rect.midY)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("splitDivider")).onChanged { drag in
                        model.splitPosition = clamped(drag.location.x / viewSize.width, in: rect)
                    }
                )
        }
        .coordinateSpace(name: "splitDivider")
        .accessibilityElement()
        .accessibilityLabel("Before and after divider")
        .accessibilityValue("\(Int(model.splitPosition * 100)) percent")
        .accessibilityAdjustableAction { direction in
            model.splitPosition = clamped(model.splitPosition + (direction == .increment ? 0.05 : -0.05), in: rect)
        }
        .accessibilityIdentifier("splitDivider")
    }

    /// Keeps the divider on the photo.
    private func clamped(_ fraction: Double, in rect: CGRect) -> Double {
        let low = max(rect.minX / viewSize.width, 0) + 0.02, high = min(rect.maxX / viewSize.width, 1) - 0.02
        return min(max(fraction, low), high)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(Theme.textPrimary)
    }
}
