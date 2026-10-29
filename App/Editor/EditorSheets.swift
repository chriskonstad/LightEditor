import EditorCore
import SwiftUI

/// Aspect presets, straighten and perspective, shown while cropping.
struct CropTools: View {
    let model: EditorModel
    var onDone: () -> Void
    @State private var customizing = false
    @State private var customWidth = ""
    @State private var customHeight = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Free", selected: model.crop.aspect == nil) { setAspect(nil) }
                    chip("Original", selected: model.crop.aspect.map { abs($0.value - originalAspect.value) < 0.001 } ?? false) {
                        setAspect(originalAspect)
                    }
                    ForEach(AspectRatio.presets, id: \.self) { aspect in
                        let oriented = orient(aspect)
                        chip(aspect == AspectRatio(65, 24) ? "\(oriented) XPan" : oriented.description,
                             selected: model.crop.aspect == oriented) { setAspect(oriented) }
                    }
                    if let custom = customAspect {
                        chip(custom.description, selected: true) { customizing = true }
                    }
                    chip("Custom…", selected: false) {
                        customWidth = model.crop.aspect.map { "\($0.width)" } ?? ""
                        customHeight = model.crop.aspect.map { "\($0.height)" } ?? ""
                        customizing = true
                    }
                    Button {
                        if let aspect = model.crop.aspect { setAspect(AspectRatio(aspect.height, aspect.width)) }
                    } label: {
                        Image(systemName: "rotate.right").frame(width: Theme.minTouch, height: 32)
                    }
                    .disabled(model.crop.aspect == nil)
                    .accessibilityLabel("Swap orientation")
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Straighten").foregroundStyle(Theme.textPrimary)
                    if let method = model.crop.auto?.method {
                        Text("Auto · \(method.displayName)")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.accent)
                            .accessibilityIdentifier("straighten.method")
                    }
                    Spacer()
                    Button {
                        model.autoStraighten()
                    } label: {
                        if model.isLeveling {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Auto", systemImage: "level")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isLeveling)
                    .accessibilityHint("Levels the photo from the camera's level, or Apple's horizon detection")
                    .accessibilityIdentifier("straighten.auto")
                    Text(String(format: "%.1f°", model.crop.angle)).valueStyle()
                }
                .font(.subheadline)
                FineSlider(
                    position: (model.crop.angle + 45) / 90,
                    origin: 0.5,
                    onChange: { position in
                        var geometry = model.crop
                        // With Auto on, the slider fine-tunes the found angle.
                        geometry.setAngle(((position * 90 - 45) * 10).rounded() / 10)
                        model.setCropLive(geometry)
                    },
                    onEditingChanged: { if !$0 { model.commitCrop() } },
                    onReset: {
                        var geometry = model.crop
                        geometry.angle = 0
                        geometry.auto = nil
                        model.set(.crop, .crop(geometry))
                    }
                )
                .accessibilityLabel("Straighten")
                .accessibilityIdentifier("slider.straighten")
            }
            ParamSlider(model: model, key: .perspectiveVertical, label: "Vertical perspective")
            ParamSlider(model: model, key: .perspectiveHorizontal, label: "Horizontal perspective")
            HStack {
                Button("Reset") {
                    model.reset(.crop)
                    model.reset(.perspectiveVertical)
                    model.reset(.perspectiveHorizontal)
                }
                .disabled(!model.hasEdits(.crop))
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(AccentButtonStyle())
                    .accessibilityIdentifier("crop.done")
            }
        }
        .alert("Custom aspect ratio", isPresented: $customizing) {
            TextField("Width", text: $customWidth)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            TextField("Height", text: $customHeight)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("Set") {
                if let width = Int(customWidth), let height = Int(customHeight), width > 0, height > 0, width <= 1000, height <= 1000 {
                    setAspect(AspectRatio(width, height))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Width and height, e.g. 65 and 24.")
        }
    }

    /// The current aspect when it isn't one of the presets or the original.
    private var customAspect: AspectRatio? {
        guard let aspect = model.crop.aspect else { return nil }
        let known = AspectRatio.presets.flatMap { [$0, AspectRatio($0.height, $0.width)] } + [originalAspect]
        return known.contains(aspect) ? nil : aspect
    }

    private var originalAspect: AspectRatio {
        let size = model.info?.nativeSize ?? CGSize(width: 3, height: 2)
        let divisor = gcd(Int(size.width), Int(size.height))
        return AspectRatio(max(Int(size.width) / max(divisor, 1), 1), max(Int(size.height) / max(divisor, 1), 1))
    }

    private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    /// Presets match the photo's orientation by default.
    private func orient(_ aspect: AspectRatio) -> AspectRatio {
        let portrait = model.frameAspect < 1
        return portrait == (aspect.width < aspect.height) || aspect.width == aspect.height ? aspect : AspectRatio(aspect.height, aspect.width)
    }

    private func setAspect(_ aspect: AspectRatio?) {
        var geometry = model.crop
        geometry.aspect = aspect
        if let aspect { geometry.rect = CropMath.centered(aspect: aspect.value, frameAspect: model.frameAspect) }
        model.set(.crop, .crop(geometry))
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(selected ? Theme.accent : Theme.panelRaised, in: Capsule())
                .foregroundStyle(selected ? Theme.onAccent : Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("aspect.\(title)")
    }
}

/// Format and size, then share or save the render.
struct ExportSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportFormat") private var format: ExportFormat = .jpeg
    /// 0 means full size.
    @AppStorage("exportMegapixels") private var megapixels: Double = 0
    @AppStorage("exportQuality") private var quality: Double = 0.9
    @State private var exported: URL?
    @State private var working = false
    @State private var errorMessage: String?
    @State private var sample: (bytes: Int, pixels: Double)?

    private var fullSize: CGSize { model.exportFullSize ?? model.displayedImageSize }

    /// Full size, then the megapixel presets smaller than the photo.
    private var sizeChoices: [Double] {
        let full = fullSize.width * fullSize.height / 1_000_000
        return [0] + ExportSizing.megapixelPresets.filter { $0 < full * 0.9 }
    }

    private var options: ExportOptions {
        ExportOptions(format: format, longEdge: megapixels == 0 ? nil : ExportSizing.longEdge(megapixels: megapixels, for: fullSize), quality: quality)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("export.format")

                Section("Size") {
                    Picker("Size", selection: $megapixels) {
                        ForEach(sizeChoices, id: \.self) { choice in
                            sizeRow(choice).tag(choice)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("export.size")
                }

                Section {
                    HStack {
                        Text("Quality")
                        Slider(value: $quality, in: 0.5...1, step: 0.05)
                            .accessibilityIdentifier("export.quality")
                        Text("\(Int((quality * 100).rounded()))%").monospacedDigit().foregroundStyle(Theme.textSecondary)
                    }
                } footer: {
                    Text("File sizes are estimates from a small render of this edit.")
                }

                Section {
                    Button("Export to \(model.app.library.displayName) as a new photo", systemImage: "photo.badge.plus") {
                        model.saveExportToLibrary(options)
                        dismiss()
                    }
                    .accessibilityIdentifier("export.saveCopy")
                    if let exported {
                        ShareLink(item: exported) {
                            Label("Share \(exported.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("export.share")
                    } else {
                        Button {
                            render()
                        } label: {
                            HStack {
                                Label(working ? "Rendering…" : "Export to share…", systemImage: "square.and.arrow.up")
                                Spacer()
                                if working { ProgressView() }
                            }
                        }
                        .disabled(working)
                        .accessibilityIdentifier("export.render")
                    }
                } footer: {
                    Text("Exporting makes a separate photo at this format and size. Your edit itself is saved to the original automatically when you leave the photo, and stays editable.")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Export")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onChange(of: format) { exported = nil }
            .onChange(of: megapixels) { exported = nil }
            .onChange(of: quality) { exported = nil }
            .task(id: "\(format.rawValue)-\(quality)") {
                // Debounce slider moves before encoding a sample.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                sample = await model.exportSample(format: format, quality: quality)
            }
            .onAppear {
                if !sizeChoices.contains(megapixels) { megapixels = 0 }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func sizeRow(_ choice: Double) -> some View {
        let edge = choice == 0 ? nil : ExportSizing.longEdge(megapixels: choice, for: fullSize)
        let size = ExportSizing.size(longEdge: edge, full: fullSize)
        let mp = size.width * size.height / 1_000_000
        var parts = ["\(Int(size.width)) × \(Int(size.height))"]
        if let sample {
            let bytes = ExportSizing.estimatedBytes(sampleBytes: sample.bytes, samplePixels: sample.pixels, targetPixels: size.width * size.height)
            parts.append("about " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(choice == 0 ? "Full size · \(Int(mp.rounded())) MP" : "\(Int(choice)) MP")
            Text(parts.joined(separator: " · ")).font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
        }
    }

    private func render() {
        working = true
        errorMessage = nil
        guard let task = model.export(options) else { working = false; return }
        Task {
            do {
                exported = try await task.value
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            working = false
        }
    }
}

/// Choose which paste groups to apply, and how.
struct PasteSheet: View {
    let clip: RecipeClip
    let count: Int
    var allowsAdjust = true
    let onPaste: (Set<PasteGroup>, PasteMode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var groups = PasteGroup.defaultSelection
    @State private var mode: PasteMode = .set

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if allowsAdjust {
                        Picker("Mode", selection: $mode) {
                            ForEach(PasteMode.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("paste.mode")
                    }
                } footer: {
                    if mode == .adjust {
                        Text("Adds each change relative to its default, e.g. +0.3 EV, on top of every photo's own edits.")
                    }
                }
                Section {
                    ForEach(rows, id: \.title) { row in
                        Toggle(isOn: Binding(
                            get: { row.groups.isSubset(of: groups) },
                            set: { on in if on { groups.formUnion(row.groups) } else { groups.subtract(row.groups) } }
                        )) {
                            VStack(alignment: .leading) {
                                Text(row.title)
                                if let subtitle = row.subtitle {
                                    Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                        .toggleStyle(CheckboxToggleStyle())
                        .accessibilityIdentifier("paste.group.\(row.title)")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onPaste(groups, mode)
                    dismiss()
                } label: {
                    Text(count == 1 ? "Paste" : "Paste to \(count) photos").frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(groups.isEmpty)
                .padding()
                .accessibilityIdentifier("paste.confirm")
            }
            .navigationTitle(count == 1 ? "Paste edits" : "Paste edits to \(count) photos")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .top) {
                Text("From \(clip.sourceName) · copied \(clip.copiedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var rows: [(title: String, subtitle: String?, groups: Set<PasteGroup>)] {
        [
            ("White balance", nil, [.whiteBalance]),
            ("Light", nil, [.light]),
            ("Color and grading", nil, [.color, .grade, .effects]),
            ("Film LUT (.cube)", nil, [.filmLUT]),
            ("Detail and noise", "Re-decodes, slower", [.detail]),
            ("Masks", "AI masks re-detect on each photo", [.masks]),
            ("Crop", "Per photo", [.crop]),
        ]
    }
}

/// A checkbox-style toggle that works the same on iOS and macOS.
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer()
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(configuration.isOn ? Theme.accent : Theme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// Bulk sliders: set or adjust a handful of common parameters across a selection.
struct BulkAdjustSheet: View {
    let count: Int
    let onApply: ([ParamKey: Double], PasteMode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: PasteMode = .adjust
    @State private var values: [ParamKey: Double] = [:]

    private let keys: [ParamKey] = [.exposure, .contrast, .highlights, .shadows, .whites, .blacks, .vibrance, .saturation, .temperature, .tint]

    var body: some View {
        NavigationStack {
            List {
                Picker("Mode", selection: $mode) {
                    ForEach(PasteMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                ForEach(keys, id: \.self) { key in
                    let spec = ParamCatalog.spec(for: key)!
                    let range = bulkRange(key, spec: spec)
                    VStack(alignment: .leading) {
                        HStack {
                            Text(spec.label)
                            Spacer()
                            Text(values[key].map { mode == .adjust ? ValueFormat.signed($0, decimals: key == .exposure ? 2 : 0) : ValueFormat.format(key, $0, defaults: .generic) } ?? "—")
                                .valueStyle()
                        }
                        Slider(value: Binding(get: { values[key] ?? neutral(key, range) }, set: { values[key] = key == .exposure ? ($0 * 100).rounded() / 100 : $0.rounded() }), in: range)
                            .tint(Theme.accent)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onApply(values, mode)
                    dismiss()
                } label: {
                    Text("Apply to \(count) photos").frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(values.isEmpty)
                .padding()
            }
            .navigationTitle("Edit \(count) photos")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Clear") { values = [:] } }
            }
            .onChange(of: mode) { values = [:] }
        }
        .presentationDetents([.large])
    }

    private func bulkRange(_ key: ParamKey, spec: ParamSpec) -> ClosedRange<Double> {
        let range = spec.range ?? -100...100
        guard mode == .adjust else { return key == .temperature ? 2500...12000 : range }
        switch key {
        case .temperature: return -3000...3000
        case .tint: return -50...50
        case .exposure: return -2...2
        default: return -50...50
        }
    }

    private func neutral(_ key: ParamKey, _ range: ClosedRange<Double>) -> Double {
        if mode == .adjust { return 0 }
        return ParamCatalog.spec(for: key)?.fixedDefault ?? (key == .temperature ? 5500 : 0)
    }
}
