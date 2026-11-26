import Foundation
import Testing
@testable import EditorCore

@Suite struct MaskOverlayVisibilityTests {
    let mask = UUID()
    let other = UUID()

    @Test func showsByDefault() {
        let state = MaskOverlayVisibility()
        #expect(state.isVisible)
        #expect(state.overlayMask(selected: mask) == mask)
        #expect(state.overlayMask(selected: nil) == nil)
    }

    @Test func firstAdjustmentHides() {
        var state = MaskOverlayVisibility()
        state.refineSelection()
        state.adjust()
        #expect(!state.isVisible)
        #expect(state.isAutoHidden)
        #expect(state.overlayMask(selected: mask) == nil)
        state.adjust()
        #expect(!state.isVisible)
    }

    @Test func refiningShowsAgainAndRearms() {
        var state = MaskOverlayVisibility()
        state.adjust()
        state.refineSelection()
        #expect(state.isVisible)
        state.adjust()
        #expect(!state.isVisible)
    }

    @Test func turningOnByHandStaysOnWhileAdjusting() {
        var state = MaskOverlayVisibility()
        state.adjust()
        state.setVisible(true)
        #expect(state.isVisible)
        state.adjust()
        state.adjust()
        #expect(state.isVisible)
        // Refining re-arms the auto-hide.
        state.refineSelection()
        state.adjust()
        #expect(!state.isVisible)
    }

    @Test func turningOffByHandSticks() {
        var state = MaskOverlayVisibility()
        state.setVisible(false)
        #expect(!state.isVisible)
        state.refineSelection()
        #expect(!state.isVisible)
        state.adjust()
        state.refineSelection()
        #expect(!state.isVisible)
        #expect(!state.isAutoHidden)
        state.setVisible(true)
        #expect(state.isVisible)
    }

    @Test func peekShowsHeldMaskWhateverTheToggle() {
        var state = MaskOverlayVisibility()
        state.adjust()
        state.peek(other)
        #expect(state.overlayMask(selected: mask) == other)
        state.peek(nil)
        #expect(state.overlayMask(selected: mask) == nil)

        state.setVisible(false)
        state.peek(mask)
        #expect(state.overlayMask(selected: mask) == mask)
        #expect(!state.isVisible, "Peeking doesn't change the toggle")
        state.peek(nil)
        #expect(state.overlayMask(selected: mask) == nil)
    }

    @Test func peekDoesNotDisarm() {
        var state = MaskOverlayVisibility()
        state.peek(mask)
        state.peek(nil)
        state.adjust()
        #expect(!state.isVisible)
    }
}
