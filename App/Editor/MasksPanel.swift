import EditorCore
import SwiftUI

/// The Masks tab: the mask list, the selected mask's parts and its local settings.
struct MasksPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.masks.isEmpty {
                PanelHeader(title: "Create a mask")
                NewMaskGrid(model: model)
            } else {
                HStack {
                    PanelHeader(title: "Masks")
                    Menu {
                        NewMaskMenuItems { model.addMask($0) }
                    } label: {
                        Label("New", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                    }
                    .accessibilityIdentifier("mask.new")
                }
                ForEach(model.masks) { layer in
                    MaskRow(model: model, layer: layer)
                }
                if let layer = model.selectedMask {
                    SelectedMaskEditor(model: model, layer: layer)
                }
            }
        }
    }
}

/// The shapes a new mask can start from, AI first.
struct NewMaskMenuItems: View {
    let action: (MaskShape) -> Void

    var body: some View {
        Section("AI") {
            ForEach([AIMaskKind.subject, .sky, .people, .background]) { kind in
                Button(kind.displayName, systemImage: kind.systemImage) { action(.ai(kind: kind)) }
            }
            Button("Object (tap to select)", systemImage: "hand.tap") { action(.object(seeds: [])) }
        }
        Section("Draw") {
            ForEach(NewMaskGrid.drawShapes, id: \.displayName) { shape in
                Button(shape.displayName, systemImage: shape.systemImage) { action(shape) }
            }
        }
        Section("Range") {
            ForEach(NewMaskGrid.rangeShapes, id: \.displayName) { shape in
                Button(shape.displayName, systemImage: shape.systemImage) { action(shape) }
            }
        }
    }
}

/// Big buttons for the first mask.
struct NewMaskGrid: View {
    let model: EditorModel

    static let drawShapes: [MaskShape] = [
        .brush(strokes: []),
        .linear(start: NormalizedPoint(x: 0.5, y: 0.1), end: NormalizedPoint(x: 0.5, y: 0.5)),
        .radial(center: NormalizedPoint(x: 0.5, y: 0.5), radiusX: 0.25, radiusY: 0.25, angle: 0, feather: 0.5),
    ]
    static let rangeShapes: [MaskShape] = [
        .luminance(low: 0.6, high: 1, feather: 0.1),
        .color(l: 0.6, a: -0.03, b: -0.1, range: 0.4),
    ]

    var body: some View {
        let shapes: [MaskShape] = [.ai(kind: .subject), .ai(kind: .sky), .ai(kind: .people), .ai(kind: .background), .object(seeds: [])]
            + Self.drawShapes + Self.rangeShapes
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
            ForEach(shapes, id: \.displayName) { shape in
                Button { model.addMask(shape) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: shape.systemImage).font(.title3)
                        Text(shape.displayName).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(shape.isAI ? Theme.accent : Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mask.create.\(shape.displayName)")
            }
        }
        Text("AI masks run on this device and re-detect on each photo they're pasted to.")
            .font(.caption2).foregroundStyle(Theme.textSecondary)
    }
}

/// One mask in the list: select, show or hide, and a menu.
struct MaskRow: View {
    let model: EditorModel
    let layer: MaskLayer

    var body: some View {
        let selected = layer.id == model.selectedMaskID
        HStack(spacing: 10) {
            Image(systemName: layer.components.first?.shape.systemImage ?? "circle.dashed")
                .frame(width: 28)
                .foregroundStyle(selected ? Theme.onAccent : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(layer.name).font(.subheadline.weight(.medium))
                let summary = layer.adjustments.isEmpty ? "No adjustments yet" : "\(layer.adjustments.count) adjustment\(layer.adjustments.count == 1 ? "" : "s")"
                Text(layer.components.count > 1 ? "\(layer.components.count) parts · \(summary)" : summary)
                    .font(.caption2)
                    .foregroundStyle(selected ? Theme.onAccent.opacity(0.8) : Theme.textSecondary)
            }
            Spacer()
            Button {
                model.setMaskEnabled(layer.id, !layer.isEnabled)
            } label: {
                Image(systemName: layer.isEnabled ? "eye" : "eye.slash")
                    .frame(width: Theme.minTouch, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(layer.isEnabled ? "Hide \(layer.name)" : "Show \(layer.name)")
            Menu {
                Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicateMask(layer.id) }
                Button("Delete", systemImage: "trash", role: .destructive) { model.deleteMask(layer.id) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 32)
            }
            .accessibilityLabel("\(layer.name) options")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: Theme.minTouch)
        .foregroundStyle(selected ? Theme.onAccent : Theme.textPrimary)
        .background(selected ? Theme.accent : Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
        .opacity(layer.isEnabled ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture { model.selectMask(layer.id) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mask.row.\(layer.name)")
    }
}

/// Parts, shape settings, amount and local sliders for the selected mask.
struct SelectedMaskEditor: View {
    @Bindable var model: EditorModel
    let layer: MaskLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                PanelHeader(title: "\(layer.name) · parts")
                Menu {
                    ForEach(MaskComponent.Operation.allCases, id: \.self) { operation in
                        Menu(operation.displayName) {
                            NewMaskMenuItems { model.addComponent($0, operation: operation) }
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus").font(.caption.weight(.semibold))
                }
                .accessibilityIdentifier("mask.addPart")
            }
            ForEach(layer.components) { component in
                ComponentRow(model: model, component: component, isOnly: layer.components.count == 1)
            }
            if let component = model.selectedComponent {
                ComponentSettings(model: model, component: component)
            }
            Toggle("Show overlay", isOn: $model.showMaskOverlay)
                .font(.subheadline)
                .tint(Theme.accent)
                .accessibilityIdentifier("mask.overlay")

            PanelHeader(title: "Adjustments")
            AmountSlider(model: model, layer: layer)
            ForEach(MaskLayer.adjustmentKeys, id: \.self) { key in
                LocalAdjustmentSlider(model: model, key: key)
            }
        }
    }
}

private struct AmountSlider: View {
    let model: EditorModel
    let layer: MaskLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Amount").foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(Int((layer.amount * 100).rounded()))%").valueStyle()
            }
            .font(.subheadline)
            FineSlider(
                position: layer.amount,
                onChange: { value in model.editSelectedMask { $0.amount = value } },
                onEditingChanged: { if !$0 { model.pushHistory(label: "\(layer.name): amount") } },
                onReset: { model.editSelectedMask("\(layer.name): amount") { $0.amount = 1 } }
            )
            .accessibilityLabel("Mask amount")
        }
    }
}

/// A local setting inside the selected mask, with the same gestures as global sliders.
struct LocalAdjustmentSlider: View {
    let model: EditorModel
    let key: ParamKey

    var body: some View {
        let range = MaskLayer.range(for: key)
        let value = model.maskValue(key)
        let title = key == .localTemperature ? "Temperature" : key == .localTint ? "Tint" : ParamCatalog.spec(for: key)?.label ?? key.rawValue
        let formatted = key == .exposure ? ValueFormat.signed(value, decimals: 2) : ValueFormat.signed(value, decimals: 0)
        let tint: Color = switch key {
        case .localTemperature: Color(hue: 0.1, saturation: 0.7, brightness: 0.9)
        case .localTint: Color(hue: 0.85, saturation: 0.6, brightness: 0.9)
        default: Theme.accent
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).foregroundStyle(value != 0 ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
                Text(formatted).valueStyle().foregroundStyle(value != 0 ? Theme.accent : Theme.textSecondary)
            }
            .font(.subheadline)
            FineSlider(
                position: (value - range.lowerBound) / (range.upperBound - range.lowerBound),
                origin: 0.5,
                tint: tint,
                onChange: { position in
                    var raw = range.lowerBound + position * (range.upperBound - range.lowerBound)
                    if abs(raw) < (range.upperBound - range.lowerBound) * 0.006 { raw = 0 }
                    model.setMaskValueLive(key, key == .exposure ? (raw * 100).rounded() / 100 : raw.rounded())
                },
                onEditingChanged: { if !$0 { model.commitMaskValue(key) } },
                onReset: {
                    model.setMaskValueLive(key, 0)
                    model.commitMaskValue(key)
                },
                onHold: { holding in
                    if let id = model.selectedMaskID { model.setHidden([.mask(id)], hidden: holding, label: "this mask") }
                }
            )
            .accessibilityLabel("Mask \(title)")
            .accessibilityValue(formatted)
            .accessibilityIdentifier("mask.slider.\(key.rawValue)")
        }
    }
}

/// One part of the mask: select it, change how it combines, invert or delete it.
struct ComponentRow: View {
    let model: EditorModel
    let component: MaskComponent
    let isOnly: Bool

    var body: some View {
        let selected = component.id == model.selectedComponent?.id
        HStack(spacing: 8) {
            Text(symbol)
                .font(.caption.weight(.bold).monospaced())
                .frame(width: 22, height: 22)
                .background(Theme.divider, in: RoundedRectangle(cornerRadius: 4))
            Image(systemName: component.shape.systemImage)
            Text(component.shape.displayName + (component.inverted ? " (inverted)" : ""))
                .font(.subheadline)
            Spacer()
            if let status = model.aiStatus(component.shape) {
                if model.computingAI.contains(component.shape) {
                    ProgressView().controlSize(.small)
                }
                Text(status).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Menu {
                Picker("Combine", selection: Binding(
                    get: { component.operation },
                    set: { op in model.editComponent(component.id, label: "\(op.displayName) part") { $0.operation = op } }
                )) {
                    ForEach(MaskComponent.Operation.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Button(component.inverted ? "Don't invert" : "Invert", systemImage: "circle.righthalf.filled") {
                    model.editComponent(component.id, label: "Invert part") { $0.inverted.toggle() }
                }
                Button(isOnly ? "Delete mask" : "Delete part", systemImage: "trash", role: .destructive) {
                    model.deleteComponent(component.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 40)
        .background(selected ? Theme.panelRaised : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Theme.accent.opacity(0.7) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedComponentID = component.id }
        .accessibilityIdentifier("mask.part.\(component.shape.displayName)")
    }

    private var symbol: String {
        switch component.operation {
        case .add: "+"
        case .subtract: "−"
        case .intersect: "∩"
        }
    }
}

/// Settings for the selected part: brush, gradient and range controls.
struct ComponentSettings: View {
    @Bindable var model: EditorModel
    let component: MaskComponent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch component.shape {
            case .brush:
                hint("Paint on the photo. Pull away from a slider for fine control.")
                Picker("Brush", selection: $model.brushErase) {
                    Label("Paint", systemImage: "paintbrush.pointed").tag(false)
                    Label("Erase", systemImage: "eraser").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("brush.mode")
                settingSlider("Size", value: model.brushSize, range: 0.005...0.2, format: "\(Int((model.brushSize * 1000).rounded()))") { model.brushSize = $0 }
                settingSlider("Feather", value: model.brushFeather, range: 0...1, format: "\(Int((model.brushFeather * 100).rounded()))%") { model.brushFeather = $0 }
                settingSlider("Flow", value: model.brushFlow, range: 0.05...1, format: "\(Int((model.brushFlow * 100).rounded()))%") { model.brushFlow = $0 }
            case .linear:
                hint("Drag the end points on the photo. The effect is strongest at the solid line.")
            case .radial(let center, let rx, let ry, let angle, let feather):
                hint("Drag the center to move, the edge handles to resize.")
                settingSlider("Feather", value: feather, range: 0...1, format: "\(Int((feather * 100).rounded()))%", commit: "Feather") { value in
                    model.editSelectedShape { $0 = .radial(center: center, radiusX: rx, radiusY: ry, angle: angle, feather: value) }
                }
                settingSlider("Angle", value: angle, range: -90...90, format: "\(Int(angle.rounded()))°", commit: "Angle") { value in
                    model.editSelectedShape { $0 = .radial(center: center, radiusX: rx, radiusY: ry, angle: value, feather: feather) }
                }
            case .luminance(let low, let high, let feather):
                LuminanceRangeBar(low: low, high: high)
                settingSlider("Dark end", value: low, range: 0...1, format: "\(Int((low * 100).rounded()))", commit: "Luminance range") { value in
                    model.editSelectedShape { $0 = .luminance(low: min(value, high - 0.02), high: high, feather: feather) }
                }
                settingSlider("Bright end", value: high, range: 0...1, format: "\(Int((high * 100).rounded()))", commit: "Luminance range") { value in
                    model.editSelectedShape { $0 = .luminance(low: low, high: max(value, low + 0.02), feather: feather) }
                }
                settingSlider("Smoothness", value: feather, range: 0.01...0.5, format: "\(Int((feather * 100).rounded()))", commit: "Luminance smoothness") { value in
                    model.editSelectedShape { $0 = .luminance(low: low, high: high, feather: value) }
                }
            case .color(let l, let a, let b, let range):
                HStack {
                    hint("Tap the photo to pick a color.")
                    Spacer()
                    Circle().fill(swatch(l: l, a: a, b: b)).frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(Theme.divider))
                }
                settingSlider("Range", value: range, range: 0.05...1, format: "\(Int((range * 100).rounded()))", commit: "Color range") { value in
                    model.editSelectedShape { $0 = .color(l: l, a: a, b: b, range: value) }
                }
            case .object:
                hint("Tap the photo to select an object. Tap again to add more of it.")
            case .ai:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.textSecondary)
    }

    private func swatch(l: Double, a: Double, b: Double) -> Color {
        // Oklab back to sRGB for a preview dot.
        let lp = l + 0.3963377774 * a + 0.2158037573 * b
        let mp = l - 0.1055613458 * a - 0.0638541728 * b
        let sp = l - 0.0894841775 * a - 1.2914855480 * b
        let (L, M, S) = (lp * lp * lp, mp * mp * mp, sp * sp * sp)
        let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        func encode(_ v: Double) -> Double { let c = min(max(v, 0), 1); return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        return Color(.sRGB, red: encode(r), green: encode(g), blue: encode(bl))
    }

    private func settingSlider(_ title: String, value: Double, range: ClosedRange<Double>, format: String, commit: String? = nil, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(format).valueStyle()
            }
            .font(.subheadline)
            FineSlider(
                position: (value - range.lowerBound) / (range.upperBound - range.lowerBound),
                onChange: { set(range.lowerBound + $0 * (range.upperBound - range.lowerBound)) },
                onEditingChanged: { editing in
                    if !editing, let commit, let name = model.selectedMask?.name { model.pushHistory(label: "\(name): \(commit.lowercased())") }
                }
            )
            .accessibilityLabel(title)
        }
    }
}

/// A gradient bar with the selected luminance band highlighted.
struct LuminanceRangeBar: View {
    let low: Double
    let high: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                Rectangle()
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .frame(width: max((high - low) * proxy.size.width, 2))
                    .offset(x: low * proxy.size.width)
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}
