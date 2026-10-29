import SwiftUI
#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass
#else
import AppKit
#endif

/// Touch callbacks shared by the fine slider and the color wheels.
struct ControlTouchHandlers {
    /// A drag started at a point in the control's coordinates.
    var began: (CGPoint) -> Void
    /// The drag moved. `fine` is true while a modifier asks for fine steps (Option on the Mac).
    var moved: (CGPoint, _ fine: Bool) -> Void
    var ended: () -> Void
    /// Press and hold without moving: true on hold, false on release.
    var hold: (Bool) -> Void
    var doubleTap: () -> Void
}

enum ControlTouchShape {
    /// Only horizontal drags start an adjustment; vertical swipes scroll the panel.
    case horizontalSlider
    /// Drags in any direction adjust (color wheels); the panel doesn't scroll from here.
    case freeform
}

extension View {
    /// Adds drag, hold and double-tap handling that cooperates with scroll views.
    func controlTouches(_ shape: ControlTouchShape, _ handlers: ControlTouchHandlers) -> some View {
        #if os(iOS)
        overlay(TouchLayer(shape: shape, handlers: handlers))
        #else
        modifier(MacControlTouches(handlers: handlers))
        #endif
    }
}

#if os(iOS)
/// UIKit recognizers, because SwiftUI's DragGesture inside a ScrollView either
/// blocks scrolling or scrolls along with the drag.
private struct TouchLayer: UIViewRepresentable {
    let shape: ControlTouchShape
    let handlers: ControlTouchHandlers

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.shape = shape
        view.handlers = handlers
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        view.shape = shape
        view.handlers = handlers
    }

    final class TouchView: UIView, UIGestureRecognizerDelegate {
        var shape: ControlTouchShape = .horizontalSlider {
            didSet { pan?.horizontalOnly = shape == .horizontalSlider }
        }
        var handlers: ControlTouchHandlers?
        private weak var pan: DirectionalPan?

        override init(frame: CGRect) {
            super.init(frame: frame)
            let pan = DirectionalPan(target: self, action: #selector(handlePan))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            addGestureRecognizer(pan)
            self.pan = pan

            let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold))
            hold.minimumPressDuration = 0.4
            hold.allowableMovement = 8
            hold.delegate = self
            addGestureRecognizer(hold)

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            let location = pan.location(in: self)
            switch pan.state {
            case .began:
                let translation = pan.translation(in: self)
                handlers?.began(CGPoint(x: location.x - translation.x, y: location.y - translation.y))
                handlers?.moved(location, false)
            case .changed:
                handlers?.moved(location, false)
            case .ended, .cancelled, .failed:
                handlers?.ended()
            default:
                break
            }
        }

        @objc private func handleHold(_ hold: UILongPressGestureRecognizer) {
            switch hold.state {
            case .began: handlers?.hold(true)
            case .ended, .cancelled, .failed: handlers?.hold(false)
            default: break
            }
        }

        @objc private func handleDoubleTap() {
            handlers?.doubleTap()
        }

        override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard recognizer is UIPanGestureRecognizer, shape == .horizontalSlider else { return true }
            // A touch that stops a scrolling panel shouldn't change a value.
            if let scrollView = enclosingScrollView, scrollView.isDecelerating || scrollView.isDragging { return false }
            return true
        }

        private var enclosingScrollView: UIScrollView? {
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView { return scrollView }
                view = current.superview
            }
            return nil
        }

        /// Wheels win over the enclosing scroll view; sliders let it have vertical swipes.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            recognizer is UIPanGestureRecognizer && shape == .freeform && other.view is UIScrollView
        }
    }
}
/// A pan that waits until the finger has clearly moved, then claims only
/// horizontal drags. Anything else fails at once, so the enclosing scroll view
/// scrolls even when the swipe starts on a slider.
private final class DirectionalPan: UIPanGestureRecognizer {
    var horizontalOnly = true
    /// How far the finger moves before the direction is decided, in points.
    static let decisionDistance: CGFloat = 10
    /// Horizontal must beat vertical by this factor (about 27° from horizontal).
    static let horizontalBias: CGFloat = 2
    private var start: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        start = touches.first?.location(in: view)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if horizontalOnly, state == .possible, let start, let point = touches.first?.location(in: view) {
            let dx = abs(point.x - start.x), dy = abs(point.y - start.y)
            // Undecided: hold back so the pan can't begin on a slightly sideways start.
            guard hypot(dx, dy) >= Self.decisionDistance else { return }
            guard dx > dy * Self.horizontalBias else {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        start = nil
    }
}
#else
/// Mouse handling: drag to adjust (hold Option for fine steps), press and hold
/// without moving to preview, double-click to reset.
private struct MacControlTouches: ViewModifier {
    let handlers: ControlTouchHandlers
    @State private var start: CGPoint?
    @State private var dragging = false
    @State private var holding = false
    @State private var holdTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if start == nil {
                            start = drag.startLocation
                            holdTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(400))
                                guard !Task.isCancelled, !dragging else { return }
                                holding = true
                                handlers.hold(true)
                            }
                        }
                        let moved = hypot(drag.translation.width, drag.translation.height)
                        if !dragging && !holding && moved > 3 {
                            dragging = true
                            holdTask?.cancel()
                            handlers.began(drag.startLocation)
                        }
                        if dragging {
                            handlers.moved(drag.location, NSEvent.modifierFlags.contains(.option))
                        }
                    }
                    .onEnded { _ in
                        holdTask?.cancel()
                        if holding { handlers.hold(false) }
                        if dragging { handlers.ended() }
                        start = nil
                        dragging = false
                        holding = false
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { handlers.doubleTap() })
    }
}
#endif
