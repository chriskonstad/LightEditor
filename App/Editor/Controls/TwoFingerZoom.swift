#if os(iOS)
import SwiftUI
import UIKit

/// Two fingers zoom and pan the photo: the photo follows the fingers' midpoint and
/// scales with their spread. A UIKit recognizer, because SwiftUI's MagnifyGesture
/// doesn't report where the fingers move, so it can't pan. It runs alongside the
/// one-finger gestures on the photo (crop handles, mask handles, panning).
struct TwoFingerZoom: UIGestureRecognizerRepresentable {
    /// The fingers' midpoint, in the view's points.
    var began: (CGPoint) -> Void
    /// The spread since the start, and the midpoint now.
    var changed: (_ scale: CGFloat, _ center: CGPoint) -> Void
    var ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> Recognizer {
        let recognizer = Recognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ recognizer: Recognizer, context: Context) {
        let center = context.converter.localLocation
        switch recognizer.state {
        case .began: began(center)
        case .changed: changed(recognizer.scale, center)
        case .ended, .cancelled, .failed: ended()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ first: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith second: UIGestureRecognizer) -> Bool { true }
    }

    /// Recognizes once two fingers are down and have moved a little, whether they
    /// spread, pinch or move together.
    final class Recognizer: UIGestureRecognizer {
        private var touches: [UITouch] = []
        private var startDistance: CGFloat = 1
        private var startCenter: CGPoint = .zero
        private(set) var scale: CGFloat = 1

        private func geometry() -> (distance: CGFloat, center: CGPoint)? {
            guard touches.count == 2, let view else { return nil }
            let a = touches[0].location(in: view), b = touches[1].location(in: view)
            return (max(hypot(a.x - b.x, a.y - b.y), 1), CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            self.touches.append(contentsOf: touches)
            if self.touches.count > 2 {
                state = state == .possible ? .failed : .ended
                return
            }
            if let start = geometry() {
                startDistance = start.distance
                startCenter = start.center
                scale = 1
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let now = geometry() else { return }
            scale = now.distance / startDistance
            switch state {
            case .possible:
                let moved = hypot(now.center.x - startCenter.x, now.center.y - startCenter.y)
                if moved > 6 || abs(now.distance - startDistance) > 6 { state = .began }
            case .began, .changed:
                state = .changed
            default:
                break
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

        private func lift(_ lifted: Set<UITouch>) {
            touches.removeAll { lifted.contains($0) }
            if state == .began || state == .changed {
                state = .ended
            } else if touches.isEmpty, state == .possible {
                state = .failed
            }
        }

        override func reset() {
            touches = []
            scale = 1
        }
    }
}
#endif
