import EditorCore
import SwiftUI

extension CanvasBackground {
    /// The same color the Metal canvas draws, so the two never show a seam.
    var color: Color { Color(hex: srgbHex) }
}

/// Chooses the color around the photo in the editor: a viewing preference
/// stored on this device, never part of the edit.
struct CanvasBackgroundPicker: View {
    @AppStorage(CanvasBackground.defaultsKey) private var background = CanvasBackground.default

    var body: some View {
        Picker(selection: $background) {
            ForEach(CanvasBackground.allCases) { option in
                Label {
                    Text(option.displayName)
                } icon: {
                    Image(systemName: "square.fill").foregroundStyle(option.color)
                }
                .tag(option)
            }
        } label: {
            Label("Background", systemImage: "circle.lefthalf.filled")
        }
        .accessibilityIdentifier("canvasBackground")
    }
}
