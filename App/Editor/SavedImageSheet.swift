import EditorCore
import SwiftUI

/// The size and quality of the image this photo's edit saves to Photos, with an
/// estimate of its file size and the size of the one saved now.
struct SavedImageSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PhotosCopy.megapixelsDefaultsKey) private var defaultMegapixels = PhotosCopy.full.maxMegapixels
    @AppStorage(PhotosCopy.qualityDefaultsKey) private var defaultQuality = PhotosCopy.full.quality
    @State private var megapixels = 0.0
    @State private var quality = PhotosCopy.full.quality
    @State private var sample: (bytes: Int, pixels: Double)?
    @State private var savedBytes: Int?
    @State private var loadedSaved = false

    private var deviceDefault: PhotosCopy { PhotosCopy(maxMegapixels: defaultMegapixels, quality: defaultQuality) }
    private var draft: PhotosCopy { PhotosCopy(maxMegapixels: megapixels, quality: quality) }
    private var fullSize: CGSize { model.savedImageFullSize ?? model.displayedImageSize }
    private var fullMegapixels: Double { fullSize.width * fullSize.height / 1_000_000 }
    private var outputSize: CGSize { draft.outputSize(full: fullSize) }

    private var usesDefault: Binding<Bool> {
        Binding {
            !model.recipe.hasOwnPhotosCopy
        } set: { useDefault in
            if useDefault {
                commit(nil)
            } else {
                commit(deviceDefault)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use the Default", isOn: usesDefault)
                        .accessibilityIdentifier("photosCopy.useDefault")
                } footer: {
                    Text("The default is \(deviceDefault.summary), set in Settings.")
                }

                Section {
                    MegapixelSlider(megapixels: $megapixels, fullMegapixels: fullMegapixels) { commit(draft) }
                    QualitySlider(quality: $quality) { commit(draft) }
                } footer: {
                    Text("Photos, iCloud and sharing use this image. Your original keeps every pixel, so you can still export at full size any time.")
                }

                Section("File Size") {
                    LabeledContent("This setting") {
                        Text(estimateText).monospacedDigit()
                    }
                    .accessibilityIdentifier("photosCopy.estimate")
                    LabeledContent("Saved in \(model.app.library.displayName) now") {
                        Text(savedText).monospacedDigit()
                    }
                    .accessibilityIdentifier("photosCopy.saved")
                }

                if draft != deviceDefault {
                    Section {
                        Button("Make \(draft.summary) the Default") {
                            defaultMegapixels = draft.maxMegapixels
                            defaultQuality = draft.quality
                        }
                    } footer: {
                        Text("For edits saved from now on, on this device.")
                    }
                }
            }
            .navigationTitle("Saved Image")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { syncFromRecipe() }
            .onChange(of: model.recipe.photosCopy(fallback: deviceDefault)) { syncFromRecipe() }
            .task(id: quality) {
                // Debounce slider moves before encoding a sample.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                sample = await model.exportSample(format: .heic, quality: quality)
            }
            .task(id: model.savedRevision) {
                savedBytes = await model.app.library.savedImageBytes(for: model.asset)
                loadedSaved = true
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var estimateText: String {
        let size = outputSize
        var parts = ["\(Int(size.width)) × \(Int(size.height))"]
        if let sample {
            let bytes = ExportSizing.estimatedBytes(sampleBytes: sample.bytes, samplePixels: sample.pixels, targetPixels: size.width * size.height)
            parts.append("about " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private var savedText: String {
        if model.isDirty { return "Saves when you leave" }
        if let savedBytes { return ByteCountFormatter.string(fromByteCount: Int64(savedBytes), countStyle: .file) }
        if !loadedSaved { return "…" }
        return model.asset.hasAdjustments ? "Not on this device" : "No edit saved"
    }

    private func syncFromRecipe() {
        let current = model.recipe.photosCopy(fallback: deviceDefault)
        megapixels = current.maxMegapixels
        quality = current.quality
    }

    /// Sets the photo's own size, or clears it back to the default.
    private func commit(_ copy: PhotosCopy?) {
        model.updateRecipe("Saved image size") { recipe, stamp in
            recipe.set(.photosMaxMegapixels, copy.map { .scalar($0.maxMegapixels) }, at: stamp)
            recipe.set(.photosQuality, copy.map { .scalar($0.quality) }, at: stamp)
        }
        syncFromRecipe()
    }
}
