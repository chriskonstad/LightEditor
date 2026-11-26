import Foundation

/// Whether the red mask overlay shows, as Lightroom does it: the overlay shows
/// while the selection is being made or refined, hides on the first change to the
/// mask's adjustments so their effect is visible, and comes back when the user
/// returns to the selection.
///
/// This is view state, never recipe state. The editor feeds it events and
/// asks `overlayMask(selected:)` which layer to tint.
public struct MaskOverlayVisibility: Equatable, Sendable {
    /// The "Show overlay" setting the user chose. Off keeps the overlay off
    /// (except while peeking) until they turn it back on.
    public private(set) var isEnabled = true
    /// Hidden by the first adjustment after a selection change.
    public private(set) var isAutoHidden = false
    /// Whether the next adjustment hides the overlay. Turning the overlay on
    /// by hand disarms it, so it stays on while the user adjusts.
    public private(set) var hidesOnAdjust = true
    /// A mask shown for as long as its row is pressed and held.
    public private(set) var peekingMask: UUID?

    public init() {}

    /// Whether the selected mask is tinted, ignoring a peek. The "Show overlay"
    /// toggle shows this.
    public var isVisible: Bool { isEnabled && !isAutoHidden }

    /// The layer to tint: a held row's mask, else the selected one while visible.
    public func overlayMask(selected: UUID?) -> UUID? {
        peekingMask ?? (isVisible ? selected : nil)
    }

    /// The user flipped "Show overlay".
    public mutating func setVisible(_ visible: Bool) {
        isEnabled = visible
        isAutoHidden = false
        hidesOnAdjust = false
    }

    /// The selection is being made or refined: a new mask or part, a brush
    /// stroke, a tap, moving a gradient, a shape or brush setting, invert or
    /// combine, picking a part or a mask. Shows the overlay again (if enabled),
    /// and the next adjustment hides it.
    public mutating func refineSelection() {
        isAutoHidden = false
        hidesOnAdjust = true
    }

    /// One of the mask's adjustments (Amount or a local slider) changed.
    public mutating func adjust() {
        guard hidesOnAdjust else { return }
        isAutoHidden = true
        hidesOnAdjust = false
    }

    /// Press and hold a mask's row to see its overlay until release, whatever
    /// the toggle says. Pass nil on release.
    public mutating func peek(_ mask: UUID?) {
        peekingMask = mask
    }
}
