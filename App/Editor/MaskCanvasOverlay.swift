import EditorCore
import SwiftUI

/// On-photo tools for the selected mask part: gradient handles, the radial ellipse,
/// brush painting and tap-to-select. Coordinates are normalized to the original,
/// uncropped image, which is what the canvas shows while editing masks.
struct MaskCanvasOverlay: View {
    let model: EditorModel
    let viewSize: CGSize
    @State private var dragStart: MaskShape?
    @State private var brushCursor: CGPoint?

    private var frame: CGRect {
        let size = model.displayedImageSize
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: viewSize) }
        let scale = min(viewSize.width / size.width, viewSize.height / size.height)
        return CGRect(x: (viewSize.width - size.width * scale) / 2, y: (viewSize.height - size.height * scale) / 2,
                      width: size.width * scale, height: size.height * scale)
    }

    private func normalized(_ point: CGPoint) -> NormalizedPoint {
        NormalizedPoint(x: min(max((point.x - frame.minX) / frame.width, 0), 1), y: min(max((point.y - frame.minY) / frame.height, 0), 1))
    }

    private func viewPoint(_ point: NormalizedPoint) -> CGPoint {
        CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
    }

    var body: some View {
        ZStack {
            switch model.selectedComponent?.shape {
            case .linear(let start, let end): linearTool(start: start, end: end)
            case .radial(let center, let rx, let ry, let angle, let feather): radialTool(center: center, rx: rx, ry: ry, angle: angle, feather: feather)
            case .brush: brushTool
            case .object(let seeds): tapTool(seeds: seeds)
            case .color: tapTool(seeds: [])
            default: EmptyView()
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
    }

    // MARK: Linear

    private func linearTool(start: NormalizedPoint, end: NormalizedPoint) -> some View {
        let a = viewPoint(start), b = viewPoint(end)
        let direction = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let length = max(hypot(direction.x, direction.y), 1)
        // A long line perpendicular to the gradient through a point.
        func across(_ p: CGPoint) -> Path {
            let nx = -direction.y / length * 2000, ny = direction.x / length * 2000
            return Path { path in
                path.move(to: CGPoint(x: p.x - nx, y: p.y - ny))
                path.addLine(to: CGPoint(x: p.x + nx, y: p.y + ny))
            }
        }
        let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        return ZStack {
            across(a).stroke(.white, lineWidth: 1.5)
            across(middle).stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            across(b).stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            Path { $0.move(to: a); $0.addLine(to: b) }.stroke(.white.opacity(0.8), lineWidth: 1)
            handle(at: a, id: "start") { translation in
                guard case .linear(let s, let e) = dragStart else { return nil }
                return .linear(start: moved(s, translation), end: e)
            }
            handle(at: b, id: "end") { translation in
                guard case .linear(let s, let e) = dragStart else { return nil }
                return .linear(start: s, end: moved(e, translation))
            }
            handle(at: middle, id: "move", size: 22) { translation in
                guard case .linear(let s, let e) = dragStart else { return nil }
                return .linear(start: moved(s, translation), end: moved(e, translation))
            }
        }
        .clipShape(Rectangle().path(in: frame))
    }

    // MARK: Radial

    private func radialTool(center: NormalizedPoint, rx: Double, ry: Double, angle: Double, feather: Double) -> some View {
        let c = viewPoint(center)
        let w = rx * frame.width, h = ry * frame.height
        let radians = -angle * .pi / 180  // Positive angles turn counterclockwise on screen.
        func rotated(_ dx: Double, _ dy: Double) -> CGPoint {
            CGPoint(x: c.x + dx * cos(radians) - dy * sin(radians), y: c.y + dx * sin(radians) + dy * cos(radians))
        }
        let ellipse = Ellipse().path(in: CGRect(x: -w, y: -h, width: w * 2, height: h * 2))
            .applying(CGAffineTransform(rotationAngle: radians))
            .applying(CGAffineTransform(translationX: c.x, y: c.y))
        let inner = Ellipse().path(in: CGRect(x: -w * (1 - feather), y: -h * (1 - feather), width: w * 2 * (1 - feather), height: h * 2 * (1 - feather)))
            .applying(CGAffineTransform(rotationAngle: radians))
            .applying(CGAffineTransform(translationX: c.x, y: c.y))
        return ZStack {
            ellipse.stroke(.white, lineWidth: 1.5)
            inner.stroke(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            handle(at: c, id: "center", size: 22) { translation in
                guard case .radial(let center, let rx, let ry, let angle, let feather) = dragStart else { return nil }
                return .radial(center: moved(center, translation), radiusX: rx, radiusY: ry, angle: angle, feather: feather)
            }
            handle(at: rotated(w, 0), id: "rx") { translation in
                guard case .radial(let center, let rx, let ry, let angle, let feather) = dragStart else { return nil }
                // Project the drag onto the ellipse's own x axis.
                let along = translation.width * cos(radians) + translation.height * sin(radians)
                return .radial(center: center, radiusX: max(rx + along / frame.width, 0.01), radiusY: ry, angle: angle, feather: feather)
            }
            handle(at: rotated(0, -h), id: "ry") { translation in
                guard case .radial(let center, let rx, let ry, let angle, let feather) = dragStart else { return nil }
                let along = -(-translation.width * sin(radians) + translation.height * cos(radians))
                return .radial(center: center, radiusX: rx, radiusY: max(ry + along / frame.height, 0.01), angle: angle, feather: feather)
            }
        }
    }

    // MARK: Brush

    private var brushTool: some View {
        let radius = model.brushSize * max(frame.width, frame.height)
        return ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            brushCursor = drag.location
                            if model.paintingStroke == nil {
                                model.beginStroke(at: normalized(drag.startLocation))
                            }
                            model.extendStroke(to: normalized(drag.location))
                        }
                        .onEnded { _ in
                            model.endStroke()
                            brushCursor = nil
                        }
                )
                .accessibilityLabel("Paint mask")
                .accessibilityIdentifier("mask.brushCanvas")
            if let brushCursor {
                Circle()
                    .strokeBorder(model.brushErase ? Color.red : .white, lineWidth: 1.5)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(brushCursor)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Tap

    private func tapTool(seeds: [NormalizedPoint]) -> some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    guard frame.contains(location) else { return }
                    model.tapForMask(at: normalized(location))
                }
                .accessibilityLabel("Tap to select")
                .accessibilityIdentifier("mask.tapCanvas")
            ForEach(Array(seeds.enumerated()), id: \.offset) { _, seed in
                Circle()
                    .fill(Theme.accent)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .position(viewPoint(seed))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Helpers

    private func moved(_ point: NormalizedPoint, _ translation: CGSize) -> NormalizedPoint {
        NormalizedPoint(x: min(max(point.x + translation.width / frame.width, -0.5), 1.5),
                        y: min(max(point.y + translation.height / frame.height, -0.5), 1.5))
    }

    /// A draggable handle. `update` maps the drag translation onto a new shape,
    /// starting from the shape at the start of the drag.
    private func handle(at point: CGPoint, id: String, size: CGFloat = 18, update: @escaping (CGSize) -> MaskShape?) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(Theme.ground, lineWidth: 1.5))
            .shadow(radius: 2)
            .frame(width: size, height: size)
            .frame(width: Theme.minTouch, height: Theme.minTouch)
            .contentShape(Rectangle())
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if dragStart == nil { dragStart = model.selectedComponent?.shape }
                        if let shape = update(drag.translation) {
                            model.editSelectedShape { $0 = shape }
                        }
                    }
                    .onEnded { _ in
                        dragStart = nil
                        if let name = model.selectedMask?.name { model.pushHistory(label: "\(name): move") }
                    }
            )
            .accessibilityIdentifier("mask.handle.\(id)")
    }
}
