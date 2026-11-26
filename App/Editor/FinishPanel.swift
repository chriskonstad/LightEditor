import EditorCore
import SwiftUI
import UniformTypeIdentifiers

/// The Finish tab: a border or canvas around the cropped photo, and a watermark
/// (text the user types, or a logo they import; there's no default either way).
/// These are output settings, not part of the look (see `Recipe`): they show here
/// and in exports and shares, not in the image saved to Photos or in presets, and
/// copy and paste as the "Border and watermark" group.
struct FinishPanel: View {
    let model: EditorModel
    @FocusState private var editingText: Bool
    /// Logo chosen in the Text/Logo switch before a file is picked.
    @State private var wantsLogo = false
    @State private var importingLogo = false
    @State private var logoError: String?
    /// Commits a color picker's changes once it stops moving: one undo step, not dozens.
    @State private var colorCommit: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("For exports and shares. The photo saved in Photos stays without a border or watermark.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
                // Starts empty: nothing is drawn until there's text or a logo.
                model.set(.watermark, on ? .watermark(Watermark()) : nil)
                wantsLogo = false
                if on { editingText = true }
            }
        )) {
            Text("Watermark").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                .fixedSize()
        }
        .tint(Theme.accent)
        .padding(.top, 16)
        .accessibilityIdentifier("toggle.watermark")

        if let mark = watermark {
            let isLogo = mark.logo != nil || wantsLogo
            Picker("Watermark kind", selection: Binding(
                get: { isLogo },
                set: { logo in
                    wantsLogo = logo
                    if !logo, mark.logo != nil { update { $0.logo = nil } }
                    if logo, mark.logo == nil { importingLogo = true }
                }
            )) {
                Text("Text").tag(false)
                Text("Logo").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(minHeight: Theme.minTouch)
            .accessibilityIdentifier("watermark.kind")

            if isLogo {
                logoRow(mark.logo)
            } else {
                TextField("Type your watermark, e.g. © Your Name", text: Binding(
                    get: { mark.text },
                    set: { text in
                        var updated = mark
                        updated.text = text
                        model.setLive(.watermark, .watermark(updated))
                    }
                ))
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(minHeight: Theme.minTouch)
                .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
                .focused($editingText)
                .onSubmit { model.commit(.watermark) }
                .onChange(of: editingText) { _, editing in if !editing { model.commit(.watermark) } }
                .accessibilityIdentifier("watermark.text")
            }

            HStack(alignment: .top, spacing: 16) {
                positionGrid(mark.position)
                VStack(alignment: .leading, spacing: 8) {
                    Text(mark.position.displayName).font(.subheadline).foregroundStyle(Theme.textPrimary)
                    // A logo keeps its own colors.
                    if !isLogo {
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
            }
            .padding(.vertical, 8)

            ParamSlider(model: model, key: .watermarkSize, label: isLogo ? "Height" : "Size")
            ParamSlider(model: model, key: .watermarkOpacity, label: "Opacity")
            ParamSlider(model: model, key: .watermarkMargin, label: "Margin")
        }
    }

    /// The chosen logo (a thumbnail and its name) and a button to pick one.
    private func logoRow(_ logo: WatermarkLogo?) -> some View {
        HStack(spacing: 12) {
            if let logo {
                LogoThumbnail(store: model.app.lutStore, logo: logo)
                Text(logo.name)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
            }
            Button(logo == nil ? "Choose Logo…" : "Replace…") { importingLogo = true }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("watermark.chooseLogo")
            if logo == nil { Spacer(minLength: 0) }
        }
        .frame(minHeight: Theme.minTouch)
        .fileImporter(isPresented: $importingLogo, allowedContentTypes: Self.logoTypes) { result in
            guard case .success(let url) = result else {
                if logo == nil { wantsLogo = false }
                return
            }
            Task { await importLogo(url) }
        }
        .alert("Couldn't use that file", isPresented: Binding(get: { logoError != nil }, set: { if !$0 { logoError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(logoError ?? "")
        }
    }

    /// PNG, JPEG, HEIC, TIFF and other images, PDF, and SVG (converted to PDF).
    static let logoTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .image, .pdf, .svg]

    private func importLogo(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let store = model.app.lutStore.logos else { return }
        do {
            let name = url.deletingPathExtension().lastPathComponent
            let logo: WatermarkLogo
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .svg) == true {
                let pdf = try await SVGToPDF.convert(try Data(contentsOf: url))
                logo = try store.importLogo(pdf: pdf, name: name)
            } else {
                logo = try store.importLogo(from: url)
            }
            wantsLogo = false
            // A logo usually wants more room than a line of text; start it larger.
            if model.recipe[.watermarkSize] == nil { model.set(.watermarkSize, .scalar(10)) }
            update { $0.logo = logo }
        } catch {
            logoError = error.localizedDescription
        }
    }

    private func update(_ change: (inout Watermark) -> Void) {
        guard var mark = watermark else { return }
        change(&mark)
        model.set(.watermark, .watermark(mark))
    }

    /// Nine cells, like the photo: tap one to put the watermark there.
    private func positionGrid(_ selected: WatermarkPosition) -> some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(0..<3) { column in
                        let position = WatermarkPosition.allCases[row * 3 + column]
                        Button { update { $0.position = position } } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(position == selected ? Theme.accent : Theme.panelRaised)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.divider))
                                .frame(width: 28, height: 22)
                                .touchTarget()
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
                .frame(minWidth: Theme.minTouch, minHeight: 32)
                .background(selected ? Theme.accent : Theme.panelRaised, in: Capsule())
                .foregroundStyle(selected ? Theme.onAccent : Theme.textPrimary)
                // A 32 pt capsule, with a 44 pt touch target around it.
                .frame(minHeight: Theme.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    /// The system color picker, ringed in amber while it holds the current color.
    private func colorPicker(_ color: SRGBColor, isCustom: Bool, id: String,
                             onChange: @escaping (SRGBColor) -> Void, onEnd: @escaping () -> Void) -> some View {
        let changed: (SRGBColor) -> Void = { newColor in
            onChange(newColor)
            colorCommit?.cancel()
            colorCommit = Task {
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { onEnd() }
            }
        }
        return ColorWell(color: color, onChange: changed)
            .overlay(Circle().strokeBorder(isCustom ? Theme.accent : .clear, lineWidth: 2).padding(2).allowsHitTesting(false))
            .accessibilityLabel("Custom color")
            .accessibilityIdentifier(id)
    }
}

/// The system color well at a full touch size. SwiftUI's ColorPicker can't be
/// resized on iOS (it stays 28–36 pt, under the 44 pt minimum), so iOS wraps
/// UIColorWell, which draws to whatever size it's given.
private struct ColorWell: View {
    let color: SRGBColor
    let onChange: (SRGBColor) -> Void

    var body: some View {
        #if os(iOS)
        Well(color: color, onChange: onChange)
            .frame(width: Theme.minTouch, height: Theme.minTouch)
        #else
        ColorPicker("Custom color", selection: Binding(
            get: { Color(.sRGB, red: color.red, green: color.green, blue: color.blue) },
            set: { newColor in
                let resolved = newColor.resolve(in: EnvironmentValues())
                onChange(SRGBColor(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue)))
            }
        ), supportsOpacity: false)
        .labelsHidden()
        .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
        #endif
    }

    #if os(iOS)
    private struct Well: UIViewRepresentable {
        let color: SRGBColor
        let onChange: (SRGBColor) -> Void

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIView(context: Context) -> UIColorWell {
            let well = UIColorWell()
            well.supportsAlpha = false
            well.title = "Custom color"
            well.addAction(UIAction { [coordinator = context.coordinator] action in
                guard let well = action.sender as? UIColorWell, let picked = well.selectedColor else { return }
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                // Photo-pipeline colors are sRGB; extended values are clamped.
                let srgb = picked.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
                    .map(UIColor.init(cgColor:)) ?? picked
                srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
                coordinator.onChange?(SRGBColor(red: min(max(r, 0), 1), green: min(max(g, 0), 1), blue: min(max(b, 0), 1)))
            }, for: .valueChanged)
            return well
        }

        func updateUIView(_ well: UIColorWell, context: Context) {
            context.coordinator.onChange = onChange
            let wanted = UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
            if well.selectedColor != wanted { well.selectedColor = wanted }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIColorWell, context: Context) -> CGSize? {
            CGSize(width: Theme.minTouch, height: Theme.minTouch)
        }

        final class Coordinator {
            var onChange: ((SRGBColor) -> Void)?
        }
    }
    #endif
}

/// A small preview of a watermark logo, on a checkerboard-free dark tile.
private struct LogoThumbnail: View {
    let store: LUTStore
    let logo: WatermarkLogo

    var body: some View {
        let aspect = store.aspectRatio(of: logo) ?? 1
        let size = aspect >= 1 ? CGSize(width: 88, height: 88 / aspect) : CGSize(width: 88 * aspect, height: 88)
        Group {
            if let image = store.image(for: logo, size: size) {
                Image(decorative: image, scale: 2)
            } else {
                Image(systemName: "questionmark.square.dashed").foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: 44, height: 44)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Logo \(logo.name)")
        .accessibilityIdentifier("watermark.logoThumbnail")
    }
}
