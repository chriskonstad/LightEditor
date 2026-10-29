import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Touch handling for painting on the photo: one finger paints (or taps), two
/// fingers pinch to zoom and pan. A second finger cancels a stroke the first
/// one started, so zooming never leaves a stray mark.
struct CanvasInputHandlers {
    var paintBegan: (CGPoint) -> Void
    var paintMoved: (CGPoint) -> Void
    var paintEnded: (CGPoint) -> Void
    var paintCancelled: () -> Void
    var tapped: (CGPoint) -> Void
    /// Two fingers down: their midpoint.
    var zoomBegan: (CGPoint) -> Void
    /// Pinch scale since the start, and the fingers' midpoint now.
    var zoomChanged: (_ scale: CGFloat, _ center: CGPoint) -> Void
    var zoomEnded: () -> Void
}

#if os(iOS)
struct CanvasInput: UIViewRepresentable {
    let handlers: CanvasInputHandlers

    func makeUIView(context: Context) -> InputView {
        let view = InputView()
        view.backgroundColor = .clear
        view.handlers = handlers
        return view
    }

    func updateUIView(_ view: InputView, context: Context) {
        view.handlers = handlers
    }

    final class InputView: UIView, UIGestureRecognizerDelegate {
        var handlers: CanvasInputHandlers?
        private let paint = UIPanGestureRecognizer()
        private let tap = UITapGestureRecognizer()
        private let pinch = UIPinchGestureRecognizer()
        private let twoFingerPan = UIPanGestureRecognizer()
        private var painting = false
        private var zooming = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            paint.maximumNumberOfTouches = 1
            paint.addTarget(self, action: #selector(handlePaint))
            tap.addTarget(self, action: #selector(handleTap))
            pinch.addTarget(self, action: #selector(handleTwoFingers))
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2
            twoFingerPan.addTarget(self, action: #selector(handleTwoFingers))
            for recognizer in [paint, tap, pinch, twoFingerPan] as [UIGestureRecognizer] {
                recognizer.delegate = self
                addGestureRecognizer(recognizer)
            }
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        @objc private func handlePaint(_ recognizer: UIPanGestureRecognizer) {
            let point = recognizer.location(in: self)
            switch recognizer.state {
            case .began:
                guard !zooming else { return }
                painting = true
                let translation = recognizer.translation(in: self)
                handlers?.paintBegan(CGPoint(x: point.x - translation.x, y: point.y - translation.y))
                handlers?.paintMoved(point)
            case .changed:
                if painting { handlers?.paintMoved(point) }
            case .ended:
                if painting { handlers?.paintEnded(point) }
                painting = false
            case .cancelled, .failed:
                if painting { handlers?.paintCancelled() }
                painting = false
            default:
                break
            }
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, !zooming else { return }
            handlers?.tapped(recognizer.location(in: self))
        }

        /// Pinch and two-finger pan feed one zoom: scale from the pinch, center from the fingers.
        @objc private func handleTwoFingers(_ recognizer: UIGestureRecognizer) {
            let center = recognizer.location(in: self)
            switch recognizer.state {
            case .began:
                if painting {
                    // The second finger landed mid-stroke: this is a zoom, not paint.
                    painting = false
                    handlers?.paintCancelled()
                    paint.isEnabled = false
                    paint.isEnabled = true
                }
                if !zooming {
                    zooming = true
                    handlers?.zoomBegan(center)
                }
            case .changed:
                guard zooming else { return }
                let scale = pinch.state == .began || pinch.state == .changed ? pinch.scale : 1
                handlers?.zoomChanged(scale, center)
            case .ended, .cancelled, .failed:
                let other = recognizer === pinch ? twoFingerPan : pinch
                let otherActive = other.state == .began || other.state == .changed
                if zooming, !otherActive {
                    zooming = false
                    handlers?.zoomEnded()
                }
            default:
                break
            }
        }

        func gestureRecognizer(_ first: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith second: UIGestureRecognizer) -> Bool {
            // Pinch and two-finger pan together; painting yields to both.
            (first === pinch && second === twoFingerPan) || (first === twoFingerPan && second === pinch)
                || (first === paint && (second === pinch || second === twoFingerPan))
                || (second === paint && (first === pinch || first === twoFingerPan))
        }
    }
}
#endif
