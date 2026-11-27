import EditorCore
import SwiftUI

/// The watermark's frame on the photo, while the Finish tab is open: drag it to
/// move it, drag the corner handle to resize and turn it (or pinch and rotate on
/// a touch screen), double-tap to straighten it. It snaps to the photo's center
/// lines and to right angles.
///
/// Placement comes from `FinishingRenderer.watermarkPlacement`, the same function
/// the render uses, so the frame always sits on what's drawn.
struct WatermarkOverlay: View {
    let model: EditorModel
    let viewSize: CGSize

    private struct DragStart {
        var center: CGPoint
        var size: Double
        var rotation: Double
        /// The handle's distance and angle from the center, for resize-and-turn.
        var distance: Double = 0
        var angle: Double = 0
    }

    @State private var start: DragStart?
    @State private var snapped = false

    /// Where things are on screen: the photo inside the finished canvas, and the
    /// watermark on it, in view points.
    private struct Geometry {
        var photo: CGRect
        var center: CGPoint
        var size: CGSize
        var rotation: Double
        /// Photo pixels (at the nominal size the placement was measured at) per point.
        var pixelsPerPoint: Double
    }

    private var geometry: Geometry? {
        guard let full = model.savedImageFullSize, full.width > 0, full.height > 0 else { return nil }
        // Placement is proportional, so measure it at a moderate size: cheap to set the text at.
        let scale = 2048 / max(full.width, full.height)
        let photoSize = CGSize(width: (full.width * scale).rounded(), height: (full.height * scale).rounded())
        let layout = Finishing.layout(photo: photoSize, recipe: model.recipe)
        let canvas = model.photoFrame(in: viewSize)
        guard layout.canvas.width > 0, canvas.width > 0,
              let placement = FinishingRenderer.watermarkPlacement(model.recipe, photo: photoSize, files: model.app.lutStore)
        else { return nil }
        let k = canvas.width / layout.canvas.width
        // The layout's origin is at the bottom left; the view's at the top left.
        let photo = CGRect(x: canvas.minX + layout.photo.minX * k, y: canvas.minY + (layout.canvas.height - layout.photo.maxY) * k,
                           width: layout.photo.width * k, height: layout.photo.height * k)
        return Geometry(
            photo: photo,
            center: CGPoint(x: photo.minX + placement.center.x * k, y: photo.minY + placement.center.y * k),
            size: CGSize(width: placement.size.width * k, height: placement.size.height * k),
            rotation: placement.rotation,
            pixelsPerPoint: 1 / k
        )
    }

    var body: some View {
        if let g = geometry, case .watermark(let mark)? = model.recipe[.watermark] {
            let padding: CGFloat = 8
            let boxSize = CGSize(width: g.size.width + padding * 2, height: g.size.height + padding * 2)
            let corner = rotate(CGPoint(x: boxSize.width / 2, y: boxSize.height / 2), by: g.rotation)
            ZStack {
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .frame(width: boxSize.width, height: boxSize.height)
                    // A generous hit area, so a small watermark is still easy to grab.
                    .contentShape(Rectangle().inset(by: -16))
                    .rotationEffect(.degrees(g.rotation))
                    .position(g.center)
                    .gesture(moveGesture(mark, g))
                    .simultaneousGesture(pinchGesture(mark))
                    .simultaneousGesture(rotateGesture(mark))
                    .onTapGesture(count: 2) { straighten(mark) }
                    .accessibilityElement()
                    .accessibilityLabel("Watermark")
                    .accessibilityHint("Drag to move. Double-tap to straighten.")
                    .accessibilityIdentifier("watermark.box")

                Circle()
                    .fill(.white)
                    .overlay(Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.black))
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .frame(width: Theme.minTouch, height: Theme.minTouch)
                    .contentShape(Circle())
                    // Kept on screen when the watermark sits at the edge of the view.
                    .position(x: min(max(g.center.x + corner.x, Theme.minTouch / 2), viewSize.width - Theme.minTouch / 2),
                              y: min(max(g.center.y + corner.y, Theme.minTouch / 2), viewSize.height - Theme.minTouch / 2))
                    .gesture(resizeGesture(mark, g))
                    .accessibilityLabel("Resize and rotate watermark")
                    .accessibilityIdentifier("watermark.handle")
            }
            .frame(width: viewSize.width, height: viewSize.height)
            .coordinateSpace(name: "watermark")
            .sensoryFeedback(.alignment, trigger: snapped) { _, new in new }
        }
    }

    // MARK: Gestures

    private func moveGesture(_ mark: Watermark, _ g: Geometry) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("watermark"))
            .onChanged { value in
                if start == nil { start = DragStart(center: g.center, size: model.value(.watermarkSize), rotation: mark.rotation) }
                guard let start else { return }
                var x = (start.center.x + value.translation.width - g.photo.minX) / g.photo.width
                var y = (start.center.y + value.translation.height - g.photo.minY) / g.photo.height
                // Snap to the photo's center lines within a few points.
                let snapX = abs(x - 0.5) * g.photo.width < 6, snapY = abs(y - 0.5) * g.photo.height < 6
                if snapX { x = 0.5 }
                if snapY { y = 0.5 }
                snapped = snapX || snapY
                var updated = mark
                updated.center = NormalizedPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
                model.setLive(.watermark, .watermark(updated))
            }
            .onEnded { _ in finish() }
    }

    /// The corner handle: its distance from the center sets the size, its angle the rotation.
    private func resizeGesture(_ mark: Watermark, _ g: Geometry) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("watermark"))
            .onChanged { value in
                let point = value.location
                let dx = point.x - g.center.x, dy = point.y - g.center.y
                if start == nil {
                    let begin = value.startLocation
                    start = DragStart(
                        center: g.center, size: model.value(.watermarkSize), rotation: mark.rotation,
                        distance: max(hypot(begin.x - g.center.x, begin.y - g.center.y), 1),
                        angle: atan2(begin.y - g.center.y, begin.x - g.center.x) * 180 / .pi
                    )
                }
                guard let start else { return }
                let ratio = hypot(dx, dy) / start.distance
                let angle = atan2(dy, dx) * 180 / .pi
                apply(mark, size: start.size * ratio, rotation: start.rotation + angle - start.angle)
            }
            .onEnded { _ in finish() }
    }

    private func pinchGesture(_ mark: Watermark) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if start == nil { start = DragStart(center: .zero, size: model.value(.watermarkSize), rotation: mark.rotation) }
                guard let start else { return }
                apply(currentMark ?? mark, size: start.size * value.magnification, rotation: nil)
            }
            .onEnded { _ in finish() }
    }

    private func rotateGesture(_ mark: Watermark) -> some Gesture {
        RotateGesture()
            .onChanged { value in
                if start == nil { start = DragStart(center: .zero, size: model.value(.watermarkSize), rotation: mark.rotation) }
                guard let start else { return }
                apply(currentMark ?? mark, size: nil, rotation: start.rotation + value.rotation.degrees)
            }
            .onEnded { _ in finish() }
    }

    private var currentMark: Watermark? {
        if case .watermark(let mark)? = model.recipe[.watermark] { return mark }
        return nil
    }

    /// Sets the size (clamped to the slider's range) and the rotation (snapped to
    /// right angles within 4°, kept in -180...180).
    private func apply(_ mark: Watermark, size: Double?, rotation: Double?) {
        if let size, let range = ParamCatalog.spec(for: .watermarkSize)?.range {
            model.setLive(.watermarkSize, (min(max(size, range.lowerBound), range.upperBound) * 10).rounded() / 10)
        }
        if let rotation {
            var degrees = rotation.truncatingRemainder(dividingBy: 360)
            if degrees > 180 { degrees -= 360 }
            if degrees < -180 { degrees += 360 }
            let right = (degrees / 90).rounded() * 90
            let snap = abs(degrees - right) < 4
            snapped = snap
            var updated = mark
            updated.rotation = snap ? right : (degrees * 10).rounded() / 10
            if updated.rotation == -180 { updated.rotation = 180 }
            model.setLive(.watermark, .watermark(updated))
        }
    }

    private func finish() {
        guard start != nil else { return }
        start = nil
        snapped = false
        model.commit(.watermark)
    }

    private func straighten(_ mark: Watermark) {
        guard mark.rotation != 0 else { return }
        var updated = mark
        updated.rotation = 0
        model.set(.watermark, .watermark(updated))
    }

    private func rotate(_ point: CGPoint, by degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: point.x * cos(radians) - point.y * sin(radians), y: point.x * sin(radians) + point.y * cos(radians))
    }
}
