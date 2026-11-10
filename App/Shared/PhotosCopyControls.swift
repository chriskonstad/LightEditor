import EditorCore
import SwiftUI

/// A maximum size in megapixels, where the right end is "Full size" (stored as 0).
struct MegapixelSlider: View {
    /// 0 is full size.
    @Binding var megapixels: Double
    /// The photo's own size, or nil for a default that applies to any photo.
    let fullMegapixels: Double?
    var onCommit: () -> Void = {}

    /// Without a photo, the slider goes to 100 MP, then full size.
    private var top: Double { max((fullMegapixels ?? 101).rounded(.down), 2) }

    private var position: Binding<Double> {
        Binding {
            megapixels <= 0 ? top : min(megapixels, top)
        } set: { value in
            megapixels = value >= top - 0.5 ? 0 : value.rounded()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Maximum size")
                Spacer()
                Text(megapixels <= 0 || megapixels >= top ? "Full size" : "\(Int(megapixels)) MP")
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            Slider(value: position, in: 1...top, step: 1) { editing in
                if !editing { onCommit() }
            }
            .accessibilityIdentifier("photosCopy.size")
        }
    }
}

/// HEIC quality as a percentage.
struct QualitySlider: View {
    @Binding var quality: Double
    var onCommit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Quality")
                Spacer()
                Text("\(Int((quality * 100).rounded()))%").monospacedDigit().foregroundStyle(Theme.textSecondary)
            }
            Slider(value: $quality, in: PhotosCopy.qualityRange, step: 0.05) { editing in
                if !editing { onCommit() }
            }
            .accessibilityIdentifier("photosCopy.quality")
        }
    }
}

extension PhotosCopy {
    /// "Full size · 90%" or "24 MP · 80%".
    var summary: String {
        "\(isFullSize ? "Full size" : "\(Int(maxMegapixels)) MP") · \(Int((quality * 100).rounded()))%"
    }
}

/// This device's default for the image saved with each edit, in Settings.
struct PhotosCopyDefaultSection: View {
    @AppStorage(PhotosCopy.megapixelsDefaultsKey) private var megapixels = PhotosCopy.full.maxMegapixels
    @AppStorage(PhotosCopy.qualityDefaultsKey) private var quality = PhotosCopy.full.quality

    var body: some View {
        Section {
            MegapixelSlider(megapixels: $megapixels, fullMegapixels: nil)
            QualitySlider(quality: $quality)
            if megapixels != PhotosCopy.full.maxMegapixels || quality != PhotosCopy.full.quality {
                Button("Back to Full Size at 90%") {
                    megapixels = PhotosCopy.full.maxMegapixels
                    quality = PhotosCopy.full.quality
                }
            }
        } header: {
            Text("Saved Image")
        } footer: {
            Text("Each edit saves an image to Photos next to your original, and that image is what Photos, iCloud and sharing use. Your original keeps every pixel, so LightEditor can always export at full size. A 60 MP photo at full size and 90% is about 5–17 MB; at 24 MP and 80%, about 1–3.5 MB. Applies to edits saved from now on; a photo can set its own in the editor’s More menu.")
        }
    }
}
