import EditorCore
import SwiftUI

/// The Finish tab: a border or canvas around the cropped photo, and a text watermark.
/// Both are recipe parameters (see `Finishing`), so they show here, in saves and
/// exports alike, and paste and save in presets as the "Border and watermark" group.
struct FinishPanel: View {
    let model: EditorModel
    @AppStorage(Watermark.defaultTextKey) private var defaultText = ""
    @FocusState private var editingText: Bool
    /// Commits a color picker's changes once it stops moving: one undo step, not dozens.
    @State private var colorCommit: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelHeader(title: "Border", model: model, group: .finishing)
            ParamSlider(model: model, key: .borderWidth, label: "Width")
            ParamSlider(model: model, key: .borderBottom)
            Text("Sizes are a share of the photo's short edge, so the border looks the same at any export size.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)

            row("Color") {
                let color = Finishing.borderColor(model.recipe)
                chip("White", selected: color == .white, id: "border.white") { model.set(.borderColor, nil) }
                chip("Black", selected: color == .black, id: "border.black") { model.set(.borderColor, .color(.black)) }
                colorPicker(color, isCustom: color != .white && color != .black, id: "border.custom") { model.setLive(.borderColor, .color($0)) }
                    onEnd: { model.commit(.borderColor) }
            }

            Text("Canvas").font(.subheadline).foregroundStyle(Theme.textPrimary).padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    let canvas = Finishing.canvas(model.recipe)
                    chip("Fit", selected: canvas == nil, id: "canvas.fit") { model.set(.borderCanvas, nil) }
                    ForEach(Finishing.canvasPresets, id: \.self) { aspect in
                        chip(aspect.description, selected: canvas == aspect, id: "canvas.\(aspect.width)x\(aspect.height)") {
                            model.set(.borderCanvas, .aspect(aspect))
                        }
                    }
                }
            }
            Text("Pads the frame to a shape, e.g. 4:5 for Instagram, without cropping the photo.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)

            watermarkSection
        }
    }

    // MARK: Watermark

    private var watermark: Watermark? {
        if case .watermark(let mark)? = model.recipe[.watermark] { return mark }
        return nil
    }

    @ViewBuilder private var watermarkSection: some View {
        Toggle(isOn: Binding(
            get: { watermark != nil },
            set: { on in
                let text = defaultText.trimmingCharacters(in: .whitespaces).isEmpty ? Watermark.fallbackText : defaultText
                model.set(.watermark, on ? .watermark(Watermark(text: text)) : nil)
            }
        )) {
            Text("Watermark").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
        }
        .tint(Theme.accent)
        .padding(.top, 16)
        .accessibilityIdentifier("toggle.watermark")

        if let mark = watermark {
            TextField("Text, e.g. © Your Name", text: Binding(
                get: { mark.text },
                set: { text in
                    var updated = mark
                    updated.text = text
                    model.setLive(.watermark, .watermark(updated))
                }
            ))
            .textFieldStyle(.roundedBorder)
            .focused($editingText)
            .onSubmit { model.commit(.watermark) }
            .onChange(of: editingText) { _, editing in if !editing { model.commit(.watermark) } }
            .accessibilityIdentifier("watermark.text")

            HStack {
                if mark.text != defaultText, !mark.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Make Default") { defaultText = mark.text }
                        .accessibilityIdentifier("watermark.makeDefault")
                }
                if !defaultText.isEmpty, mark.text != defaultText {
                    Button("Use “\(defaultText)”") { update { $0.text = defaultText } }
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)

            HStack(alignment: .top, spacing: 16) {
                positionGrid(mark.position)
                VStack(alignment: .leading, spacing: 8) {
                    Text(mark.position.displayName).font(.subheadline).foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 8) {
                        chip("White", selected: mark.color == .white, id: "watermark.white") { update { $0.color = .white } }
                        chip("Black", selected: mark.color == .black, id: "watermark.black") { update { $0.color = .black } }
                        colorPicker(mark.color, isCustom: mark.color != .white && mark.color != .black, id: "watermark.custom") { color in
                            var updated = mark
                            updated.color = color
                            model.setLive(.watermark, .watermark(updated))
                        } onEnd: { model.commit(.watermark) }
                    }
                }
            }
            .padding(.vertical, 8)

            ParamSlider(model: model, key: .watermarkSize, label: "Size")
            ParamSlider(model: model, key: .watermarkOpacity, label: "Opacity")
            ParamSlider(model: model, key: .watermarkMargin, label: "Margin")
        }
    }

    private func update(_ change: (inout Watermark) -> Void) {
        guard var mark = watermark else { return }
        change(&mark)
        model.set(.watermark, .watermark(mark))
    }

    /// Nine cells, like the photo: tap one to put the watermark there.
    private func positionGrid(_ selected: WatermarkPosition) -> some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(0..<3) { column in
                        let position = WatermarkPosition.allCases[row * 3 + column]
                        Button { update { $0.position = position } } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(position == selected ? Theme.accent : Theme.panelRaised)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.divider))
                                .frame(width: 28, height: 22)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(position.displayName)
                        .accessibilityAddTraits(position == selected ? .isSelected : [])
                        .accessibilityIdentifier("watermark.position.\(position.rawValue)")
                    }
                }
            }
        }
    }

    // MARK: Controls

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(Theme.textPrimary)
            Spacer()
            content()
        }
        .frame(minHeight: Theme.minTouch)
    }

    private func chip(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .monospacedDigit()
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(selected ? Theme.accent : Theme.panelRaised, in: Capsule())
                .foregroundStyle(selected ? Theme.onAccent : Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    /// The system color picker, ringed in amber while it holds the current color.
    private func colorPicker(_ color: SRGBColor, isCustom: Bool, id: String,
                             onChange: @escaping (SRGBColor) -> Void, onEnd: @escaping () -> Void) -> some View {
        ColorPicker("Custom color", selection: Binding(
            get: { Color(.sRGB, red: color.red, green: color.green, blue: color.blue) },
            set: { newColor in
                let resolved = newColor.resolve(in: EnvironmentValues())
                onChange(SRGBColor(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue)))
                colorCommit?.cancel()
                colorCommit = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !Task.isCancelled { onEnd() }
                }
            }
        ), supportsOpacity: false)
        .labelsHidden()
        .padding(2)
        .overlay(Circle().strokeBorder(isCustom ? Theme.accent : .clear, lineWidth: 2))
        .accessibilityIdentifier(id)
    }
}

/// Settings › Watermark: the text new watermarks start with.
struct WatermarkDefaultSection: View {
    @AppStorage(Watermark.defaultTextKey) private var defaultText = ""

    var body: some View {
        Section {
            TextField("© Your Name", text: $defaultText)
                .accessibilityIdentifier("settings.watermarkText")
        } header: {
            Text("Watermark")
        } footer: {
            Text("New watermarks (Finish tab) start with this text.")
        }
    }
}
