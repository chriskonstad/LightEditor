import CoreGraphics
import Foundation

/// Crop rectangle math in normalized frame coordinates (origin top-left).
///
/// A pixel aspect ratio becomes a different normalized ratio on a non-square frame,
/// so every function takes the frame's own aspect (width / height).
public enum CropMath {
    public enum Corner: CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight

        public var opposite: Corner {
            switch self {
            case .topLeft: .bottomRight
            case .topRight: .bottomLeft
            case .bottomLeft: .topRight
            case .bottomRight: .topLeft
            }
        }

        /// The corner's position in a view-space rect.
        public func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    /// The smallest crop side, as a fraction of the frame.
    public static let minimumSize = 0.08

    /// Moves one corner of `start` by (dx, dy), keeping the opposite corner fixed,
    /// the rect inside the frame, and the aspect ratio if one is set.
    public static func resize(_ start: NormalizedRect, dragging corner: Corner, dx: Double, dy: Double, aspect: Double?, frameAspect: Double) -> NormalizedRect {
        var left = start.x, top = start.y, right = start.x + start.width, bottom = start.y + start.height
        // Only the dragged edges move; each is clamped against the frame and the fixed edge.
        switch corner {
        case .topLeft, .bottomLeft: left = min(max(left + dx, 0), right - minimumSize)
        case .topRight, .bottomRight: right = max(min(right + dx, 1), left + minimumSize)
        }
        switch corner {
        case .topLeft, .topRight: top = min(max(top + dy, 0), bottom - minimumSize)
        case .bottomLeft, .bottomRight: bottom = max(min(bottom + dy, 1), top + minimumSize)
        }
        let rect = NormalizedRect(x: left, y: top, width: right - left, height: bottom - top)
        guard let aspect else { return rect }
        return constrain(rect, to: aspect, frameAspect: frameAspect, fixedCorner: corner.opposite)
    }

    /// Moves the whole rect by (dx, dy), keeping it inside the frame.
    public static func move(_ start: NormalizedRect, dx: Double, dy: Double) -> NormalizedRect {
        var rect = start
        rect.x = min(max(start.x + dx, 0), 1 - start.width)
        rect.y = min(max(start.y + dy, 0), 1 - start.height)
        return rect
    }

    /// Shrinks `rect` to a pixel aspect ratio, keeping `fixedCorner` where it is.
    public static func constrain(_ rect: NormalizedRect, to aspect: Double, frameAspect: Double, fixedCorner: Corner) -> NormalizedRect {
        let normalized = aspect / frameAspect
        var width = rect.width, height = rect.height
        if width / height > normalized { width = height * normalized } else { height = width / normalized }
        var result = rect
        result.width = width
        result.height = height
        switch fixedCorner {
        case .topLeft: break
        case .topRight: result.x = rect.x + rect.width - width
        case .bottomLeft: result.y = rect.y + rect.height - height
        case .bottomRight:
            result.x = rect.x + rect.width - width
            result.y = rect.y + rect.height - height
        }
        return result
    }

    /// The largest centered rect with a pixel aspect ratio.
    public static func centered(aspect: Double, frameAspect: Double) -> NormalizedRect {
        let normalized = aspect / frameAspect
        if normalized >= 1 {
            let height = 1 / normalized
            return NormalizedRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
        return NormalizedRect(x: (1 - normalized) / 2, y: 0, width: normalized, height: 1)
    }
}
