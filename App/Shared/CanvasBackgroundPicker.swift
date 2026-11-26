import EditorCore
import SwiftUI

extension CanvasBackground {
    /// The same color the Metal canvas draws, so the two never show a seam.
    var color: Color { Color(hex: srgbHex) }

    /// A square of this color that keeps its color in menus, which otherwise draw
    /// every image as a template in the tint color (all six swatches came out amber).
    var swatch: Image {
        #if os(macOS)
        let configuration = NSImage.SymbolConfiguration(paletteColors: [NSColor(color)])
        let image = NSImage(systemSymbolName: "square.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return Image(nsImage: image)
        #else
        let image = UIImage(systemName: "square.fill")?
            .withTintColor(UIColor(color), renderingMode: .alwaysOriginal) ?? UIImage()
        return Image(uiImage: image)
        #endif
    }
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
                    option.swatch
                }
                .tag(option)
            }
        } label: {
            Label("Background", systemImage: "circle.lefthalf.filled")
        }
        .accessibilityIdentifier("canvasBackground")
    }
}
