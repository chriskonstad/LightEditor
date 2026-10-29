import EditorCore
import SwiftUI
import UniformTypeIdentifiers

/// The content of one editor tab. Shared by the iPhone sheet and the iPad/Mac inspector.
struct EditorPanel: View {
    let model: EditorModel
    let tab: EditorModel.Tab

    var body: some View {
        switch tab {
        case .light: LightPanel(model: model)
        case .color: ColorPanel(model: model)
        case .grade: GradePanel(model: model)
        case .detail: DetailPanel(model: model)
        case .masks: MasksPanel(model: model)
        case .presets: PresetsPanel(model: model)
        }
    }
}

struct LightPanel: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .lastTextBaseline) {
                PanelHeader(title: "Light", model: model, group: .light)
                Button("Auto") { model.autoTone() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.phase != .ready)
                    .accessibilityIdentifier("light.auto")
            }
            ForEach([ParamKey.exposure, .contrast, .highlights, .shadows, .whites, .blacks], id: \.self) { key in
                ParamSlider(model: model, key: key)
            }
            PanelHeader(title: "Presence")
            ForEach([ParamKey.clarity, .texture, .dehaze], id: \.self) { key in
                ParamSlider(model: model, key: key)
            }
            PanelHeader(title: "Tone curve")
            ToneCurveEditor(model: model)
                .padding(.bottom, 4)
        }
    }
}

struct ColorPanel: View {
    @Bindable var model: EditorModel
    @AppStorage("hslMixerMode") private var mixerMode: MixerMode = .byColor

    enum MixerMode: Hashable, RawRepresentable {
        case byColor
        case byProperty(HSLComponent)

        init?(rawValue: String) {
            if rawValue == "color" { self = .byColor } else if let component = HSLComponent(rawValue: rawValue) { self = .byProperty(component) } else { return nil }
        }

        var rawValue: String {
            switch self {
            case .byColor: "color"
            case .byProperty(let component): component.rawValue
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelHeader(title: "White balance", model: model, group: .whiteBalance)
            ParamSlider(model: model, key: .temperature, trackTint: Color(hue: 0.1, saturation: 0.7, brightness: 0.9))
            ParamSlider(model: model, key: .tint, trackTint: Color(hue: 0.85, saturation: 0.6, brightness: 0.9))

            PanelHeader(title: "Color", model: model, group: .color)
            ParamSlider(model: model, key: .vibrance)
            ParamSlider(model: model, key: .saturation)

            PanelHeader(title: "HSL mixer")
            Picker("Mixer view", selection: $mixerMode) {
                Text("Color").tag(MixerMode.byColor)
                ForEach(HSLComponent.allCases, id: \.self) { Text($0.displayName).tag(MixerMode.byProperty($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("hsl.mode")
            switch mixerMode {
            case .byColor:
                HueSwatches(selection: $model.selectedBand, model: model)
                let band = model.selectedBand
                let tint = Color(hue: band.swatchHue / 360, saturation: 0.75, brightness: 0.9)
                ForEach(HSLComponent.allCases, id: \.self) { component in
                    ParamSlider(model: model, key: .hsl(band, component), label: "\(band.displayName) \(component.displayName.lowercased())", trackTint: tint)
                }
            case .byProperty(let component):
                // Lightroom's layout: one property, all eight colors.
                ForEach(HueBand.allCases) { band in
                    ParamSlider(model: model, key: .hsl(band, component), label: band.displayName,
                                trackTint: Color(hue: band.swatchHue / 360, saturation: 0.75, brightness: 0.9))
                }
            }
        }
    }
}

struct GradePanel: View {
    let model: EditorModel
    @State private var importingLUT = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelHeader(title: "Color grading", model: model, group: .grade)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(ToneRange.allCases) { range in
                    ColorWheel(model: model, range: range, diameter: 118)
                }
            }
            Text("Drag a wheel's puck; pull your finger outside the wheel for fine control.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
            ForEach(ToneRange.allCases) { range in
                ParamSlider(model: model, key: .gradeLuminance(range), label: "\(range.displayName) luminance")
            }
            ParamSlider(model: model, key: .gradeBlending)
            ParamSlider(model: model, key: .gradeBalance)

            PanelHeader(title: "Film LUT", model: model, group: .filmLUT)
            lutPicker
            if case .lut(let ref, let amount)? = model.recipe[.lut] {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Amount").foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("\(Int(amount * 100))%").valueStyle()
                    }
                    .font(.subheadline)
                    FineSlider(
                        position: amount,
                        onChange: { model.setLive(.lut, .lut(ref, amount: $0)) },
                        onEditingChanged: { if !$0 { model.commit(.lut) } },
                        onReset: { model.set(.lut, .lut(ref, amount: 1)) },
                        onHold: { model.setHidden([.lut], hidden: $0, label: "LUT") }
                    )
                    .accessibilityLabel("LUT amount")
                }
                .frame(minHeight: Theme.minTouch)
                if model.app.lutStore.lut(for: ref) == nil {
                    Label("“\(ref.name)” isn't on this device. Import it to see it.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }

            PanelHeader(title: "Effects", model: model, group: .effects)
            ParamSlider(model: model, key: .vignetteAmount)
            ParamSlider(model: model, key: .vignetteMidpoint)
            ParamSlider(model: model, key: .grainAmount)
            ParamSlider(model: model, key: .grainSize)
        }
        .fileImporter(isPresented: $importingLUT, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result, let ref = model.app.importLUT(url) {
                model.set(.lut, .lut(ref, amount: 1))
            } else {
                model.app.showToast("That file isn't a readable .cube LUT")
            }
        }
    }

    private var lutPicker: some View {
        let current: LUTRef? = if case .lut(let ref, _)? = model.recipe[.lut] { ref } else { nil }
        return Menu {
            Button("None") { model.set(.lut, nil) }
            ForEach(model.app.luts, id: \.hash) { ref in
                Button(ref.name) { model.set(.lut, .lut(ref, amount: 1)) }
            }
            Divider()
            Button("Import .cube…", systemImage: "square.and.arrow.down") { importingLUT = true }
        } label: {
            HStack {
                Text(current?.name ?? "None").foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: Theme.minTouch)
            .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityIdentifier("lutPicker")
    }
}

struct DetailPanel: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(model.info?.isRAW == false
                     ? "Detail uses Core Image's noise reduction and sharpening for this file, applied before grading."
                     : "Detail runs in the RAW \(model.info?.decoderVersion ?? "9") decoder. Changes re-decode in the background; the current render stays on screen until the new one is ready.")
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
            .padding(10)
            .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))

            PanelHeader(title: "Detail", model: model, group: .detail)
            ParamSlider(model: model, key: .noiseReduction)
            if model.info?.isRAW != false {
                ParamSlider(model: model, key: .colorNoise)
            }
            ParamSlider(model: model, key: .sharpness)
            if model.info?.isRAW != false {
                ParamSlider(model: model, key: .detail)
                ParamSlider(model: model, key: .moire)
                Toggle(isOn: Binding(
                    get: { model.value(.lensCorrection) >= 0.5 },
                    set: { model.setLensCorrection($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lens corrections").foregroundStyle(Theme.textPrimary)
                        Text(model.info?.lensCorrectionSupported == false
                             ? "No lens profile for this camera and lens."
                             : "Distortion, vignetting and color fringing, from the camera's lens profile.")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .tint(Theme.accent)
                .disabled(model.info?.lensCorrectionSupported == false)
                .padding(.top, 8)
                .accessibilityIdentifier("toggle.lensCorrection")
            }
        }
    }
}

struct PresetsPanel: View {
    let model: EditorModel
    @State private var importing = false
    @State private var naming = false
    @State private var newName = ""
    @State private var message: String?

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let shotAs = model.cameraFilmSimulation {
                Button {
                    model.apply(shotAs)
                } label: {
                    Label("Shot as \(shotAs.name) · Apply", systemImage: "camera.filters")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("preset.shotAs")
            }
            PanelHeader(title: "Presets")
            LazyVGrid(columns: columns, spacing: 8) {
                PresetTile(model: model, preset: nil, title: "Original")
                ForEach(BuiltInPresets.all) { preset in
                    PresetTile(model: model, preset: preset, title: preset.name)
                }
            }
            PanelHeader(title: "Adaptive (AI masks)")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(AdaptivePresets.all) { preset in
                    PresetTile(model: model, preset: preset, title: preset.name)
                }
            }
            PanelHeader(title: "Fujifilm film simulations")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(FilmSimulations.presets) { preset in
                    PresetTile(model: model, preset: preset, title: preset.name,
                               badge: preset.id == model.cameraFilmSimulation?.id ? "camera" : nil)
                }
            }
            Text("Approximations of each look, made with this app's controls.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
            PanelHeader(title: "My presets")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.app.userPresets) { preset in
                    PresetTile(model: model, preset: preset, title: preset.name)
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) { model.app.delete(preset) }
                        }
                }
                Button { importing = true } label: {
                    Theme.panelRaised
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.down").font(.title3)
                                Text("Import…").font(.caption)
                            }
                            .foregroundStyle(Theme.textSecondary)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("preset.import")
            }

            if let preset = model.activePreset {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Amount · \(preset.name)").foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("\(Int(model.presetAmount * 100))%").valueStyle()
                    }
                    .font(.subheadline)
                    FineSlider(
                        position: model.presetAmount / 1.5,
                        onChange: { model.setPresetAmount($0 * 1.5, commit: false) },
                        onEditingChanged: { if !$0 { model.setPresetAmount(model.presetAmount, commit: true) } },
                        onReset: { model.setPresetAmount(1, commit: true) }
                    )
                    .accessibilityLabel("Preset amount")
                    Text(preset.params.keys.contains(.lut)
                         ? "Applies its LUT; the strength is under Color › Film LUT."
                         : "Sets the sliders in Light, Color and Grade. Fine-tune them there; this amount goes away once you do.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 4)
                }
                .frame(minHeight: Theme.minTouch)
            }

            Button("Save current edits as preset…", systemImage: "plus") {
                newName = ""
                naming = true
            }
            .disabled(model.recipe.isIdentity)
            .padding(.top, 4)
            .accessibilityIdentifier("preset.save")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { message = model.app.importPresetFile(url) }
        }
        .alert("New preset", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                model.app.savePreset(named: name.isEmpty ? "My preset" : name, from: model.recipe, groups: Set(PasteGroup.allCases).subtracting([.crop, .detail]))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves everything except Crop and Detail.")
        }
        .alert("Import", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}

/// A tile rendered live from the current photo with the preset applied.
struct PresetTile: View {
    let model: EditorModel
    let preset: Preset?
    let title: String
    /// An SF Symbol shown in the corner, e.g. for the camera's own film simulation.
    var badge: String?
    @State private var image: CGImage?

    var body: some View {
        let selected = preset != nil && model.activePreset?.id == preset?.id
        Button { model.apply(preset) } label: {
            VStack(spacing: 4) {
                Theme.panelRaised
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Image(systemName: badge)
                                .font(.caption2.weight(.bold))
                                .padding(4)
                                .background(Theme.accent, in: Circle())
                                .foregroundStyle(Theme.onAccent)
                                .padding(4)
                        }
                    }
                    .contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: selected ? 2 : 0))
                Text(title).font(.caption).lineLimit(1).foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("preset.\(title)")
        .task(id: TileKey(phase: model.phase, preset: preset?.id, base: model.history.first?.id)) {
            image = await model.presetThumbnail(preset)?.image
        }
    }

    struct TileKey: Hashable {
        var phase: EditorModel.Phase
        var preset: UUID?
        var base: UUID?
    }
}

extension EditorModel.Phase: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .opening: hasher.combine(0)
        case .decoding: hasher.combine(1)
        case .ready: hasher.combine(2)
        case .failed: hasher.combine(3)
        }
    }
}
