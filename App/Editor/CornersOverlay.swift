import EditorCore
import SwiftUI

/// Four-corner perspective: drag each corner onto something that should be
/// rectangular (a facade, a sign, a painting). The photo shows before any
/// perspective, straighten or crop; a grid inside the shape follows its
/// perspective, so its lines can be laid along the subject's edges. Done applies it.
struct CornersOverlay: View {
    let model: EditorModel
    let viewSize: CGSize
    @State private var start: PerspectiveQuad?
    @State private var dragging: Int?

    private var frame: CGRect { model.photoFrame(in: viewSize) }

    var body: some View {
        let frame = self.frame
        let quad = model.perspectiveCorners ?? CornersOverlay.startingQuad
        let points = quad.corners.map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
        ZStack {
            // Dim outside the shape.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: viewSize))
                path.addLines(points)
                path.closeSubpath()
            }
            .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // A 4 × 4 grid that follows the shape's perspective.
            Path { path in
                for i in 1..<4 {
                    let t = CGFloat(i) / 4
                    path.move(to: lerp(points[0], points[3], t)); path.addLine(to: lerp(points[1], points[2], t))
                    path.move(to: lerp(points[0], points[1], t)); path.addLine(to: lerp(points[3], points[2], t))
                }
            }
            .stroke(.white.opacity(0.4), lineWidth: 0.75)
            .allowsHitTesting(false)

            Path { path in
                path.addLines(points)
                path.closeSubpath()
            }
            .stroke(Theme.accent, lineWidth: 1.5)
            .allowsHitTesting(false)

            ForEach(0..<4, id: \.self) { index in
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 2).background(Circle().fill(Theme.accent.opacity(dragging == index ? 0.9 : 0.5)))
                        .frame(width: dragging == index ? 26 : 20, height: dragging == index ? 26 : 20)
                }
                .frame(width: Theme.minTouch, height: Theme.minTouch)
                .contentShape(Rectangle())
                .position(points[index])
                .gesture(drag(index, frame: frame))
                .accessibilityLabel(Self.names[index])
                .accessibilityIdentifier("corner.\(index)")
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .sensoryFeedback(.selection, trigger: dragging)
    }

    static let names = ["Top left corner", "Top right corner", "Bottom right corner", "Bottom left corner"]
    static let startingQuad = PerspectiveQuad.inset(0.12)

    private func drag(_ index: Int, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let begin = start ?? model.perspectiveCorners ?? Self.startingQuad
                if start == nil { start = begin; dragging = index }
                var corners = begin.corners
                let p = corners[index]
                corners[index] = NormalizedPoint(
                    x: min(max(p.x + value.translation.width / frame.width, 0), 1),
                    y: min(max(p.y + value.translation.height / frame.height, 0), 1)
                )
                let moved = PerspectiveQuad(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3])
                // Never let the shape fold over itself.
                if moved.isValid { model.setLive(.perspectiveCorners, .quad(moved)) }
            }
            .onEnded { _ in
                start = nil
                dragging = nil
                model.commit(.perspectiveCorners)
            }
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}
