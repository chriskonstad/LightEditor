import EditorCore
import SwiftUI

/// Owns the `EditorModel` for the selected asset, replacing it (and saving the old
/// one) when the selection changes, e.g. from the filmstrip.
struct EditorContainer<Content: View>: View {
    let app: AppModel
    let asset: PhotoAsset
    @ViewBuilder var content: (EditorModel) -> Content
    @State private var model: EditorModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                Theme.ground
            }
        }
        .task(id: asset.id) {
            model?.close()
            let next = EditorModel(app: app, asset: asset)
            model = next
            app.activeEditor = next
            await next.open()
        }
        .onDisappear { model?.close() }
        .focusedSceneValue(\.editor, model)
    }
}

extension FocusedValues {
    @Entry var editor: EditorModel?
}

// MARK: - iPhone

/// The compact editor: photo on top, tabs below, actions along the bottom.
struct CompactEditorView: View {
    @Bindable var model: EditorModel
    /// On an iPad in portrait: a taller photo, and tools kept to a readable width.
    var roomy = false
    @Environment(\.dismiss) private var dismiss

    private var photoFraction: CGFloat {
        if model.isCropping || model.isRetouching { return roomy ? 0.6 : 0.55 }
        return roomy ? 0.5 : 0.42
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                topBar
                PhotoCanvas(model: model)
                    .frame(height: proxy.size.height * photoFraction)
                ProgressLine(active: model.isRedecoding || model.phase == .decoding)
                if model.isCropping {
                    ScrollView {
                        CropTools(model: model) { model.isCropping = false }
                            .padding()
                            .frame(maxWidth: roomy ? 680 : .infinity)
                            .frame(maxWidth: .infinity)
                    }
                } else if model.isRetouching {
                    ScrollView {
                        RetouchTools(model: model) { model.isRetouching = false }
                            .padding()
                            .frame(maxWidth: roomy ? 680 : .infinity)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    tabPicker
                    ScrollView {
                        if let notice = model.foreignEdit {
                            Label(notice, systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(Theme.textSecondary)
                                .padding(10)
                                .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
                                .padding([.horizontal, .top])
                        }
                        EditorPanel(model: model, tab: model.tab)
                            .padding(.horizontal)
                            .padding(.bottom, 12)
                            .frame(maxWidth: roomy ? 680 : .infinity)
                            .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .id(model.tab)  // Each tab opens at its top.
                    bottomBar
                }
            }
        }
        .background(Theme.ground)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .overlay(alignment: .bottom) { ToastView(message: model.app.toast).padding(.bottom, 70) }
        .animation(.default, value: model.app.toast)
        .sheet(isPresented: $model.showExport) { ExportSheet(model: model) }
        .sheet(isPresented: $model.showPaste) {
            if let clip = model.app.clipboard {
                PasteSheet(clip: clip, count: 1) { groups, mode in model.paste(clip, groups: groups, mode: mode) }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                    Text("Library")
                }
                .frame(minHeight: Theme.minTouch)
            }
            .accessibilityIdentifier("editor.back")
            Spacer()
            Group {
                if model.isRedecoding {
                    Label("Re-decoding RAW \(model.info?.decoderVersion ?? "")", systemImage: "arrow.triangle.2.circlepath")
                } else if model.phase == .decoding {
                    Label("Decoding RAW \(model.info?.decoderVersion ?? "")", systemImage: "hourglass")
                } else {
                    HStack(spacing: 6) {
                        Text(model.filename)
                        PreviewStatusIndicator(model: model)
                    }
                }
            }
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(Theme.textPrimary)
            .accessibilityIdentifier("editor.title")
            Spacer()
            JobTrayPill(jobs: model.app.jobs)
            EditorMoreMenu(model: model, pasting: $model.showPaste)
        }
        .padding(.horizontal)
        .frame(height: 48)
        .background(Theme.panel)
    }

    private var tabPicker: some View {
        Picker("Tab", selection: $model.tab) {
            ForEach(EditorModel.Tab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: roomy ? 680 : .infinity)
        .accessibilityIdentifier("editor.tabs")
    }

    private var bottomBar: some View {
        HStack {
            bottomButton("Copy edits", systemImage: "doc.on.doc", id: "copy") { model.copyEdits() }
                .disabled(model.recipe.isIdentity)
            Spacer()
            bottomButton("Crop", systemImage: "crop.rotate", id: "crop") {
                model.zoom = .fit
                model.isCropping = true
            }
            .disabled(model.phase != .ready)
            Spacer()
            bottomButton("Retouch", systemImage: "bandage", id: "retouch") {
                model.isRetouching = true
            }
            .disabled(model.phase != .ready)
            Spacer()
            bottomButton("Undo", systemImage: "arrow.uturn.backward", id: "undo") { model.undo() }
                .disabled(!model.canUndo)
            Spacer()
            Button {
                model.showExport = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(model.phase != .ready)
            .accessibilityIdentifier("editor.export")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: roomy ? 680 : .infinity)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
    }

    private func bottomButton(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.body)
                Text(title).font(.caption2)
            }
            .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
        }
        .foregroundStyle(Theme.textPrimary)
        .accessibilityIdentifier("editor.\(id)")
    }
}

/// The thin line under the photo while a RAW re-decode runs.
struct ProgressLine: View {
    let active: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            if active {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: proxy.size.width * 0.3)
                    .offset(x: phase * proxy.size.width * 1.3 - proxy.size.width * 0.3)
                    .onAppear {
                        phase = 0
                        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
                    }
            }
        }
        .frame(height: 2)
        .clipped()
        .accessibilityHidden(!active)
        .accessibilityLabel("Decoding")
    }
}

/// Paste, match previous, snapshots, clipping, reset and revert.
struct EditorMoreMenu: View {
    @Bindable var model: EditorModel
    @Binding var pasting: Bool

    var body: some View {
        Menu {
            Button("Paste edits…", systemImage: "doc.on.clipboard") { model.showPaste = true }
                .disabled(model.app.clipboard == nil)
            Button("Match previous", systemImage: "arrow.turn.down.right") { model.matchPrevious() }
                .disabled(model.app.previousEdit == nil)
            Divider()
            Toggle("Show clipping", systemImage: "exclamationmark.triangle", isOn: $model.showClipping)
            Toggle("Before/after split", systemImage: "rectangle.split.2x1", isOn: $model.splitView)
            Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
                .disabled(!model.canRedo)
            Button("Take snapshot", systemImage: "camera.on.rectangle") { model.takeSnapshot() }
            if !model.snapshots.isEmpty {
                Menu("Snapshots") {
                    ForEach(model.snapshots) { step in
                        Button(step.label) { model.jump(to: step) }
                    }
                }
            }
            Divider()
            Button("Save edit now", systemImage: "square.and.arrow.down") { model.saveIfNeeded() }
                .disabled(!model.isDirty)
            Button("Back to when opened", systemImage: "clock.arrow.circlepath") { model.returnToOpened() }
                .disabled(!model.canReturnToOpened)
            Button("Reset all edits", systemImage: "arrow.counterclockwise", role: .destructive) { model.resetAll() }
                .disabled(model.recipe.isIdentity)
            Button("Revert to original", systemImage: "clock.arrow.circlepath", role: .destructive) { model.revertToOriginal() }
                .disabled(!model.asset.hasAdjustments && model.foreignEdit == nil)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(width: Theme.minTouch, height: Theme.minTouch)
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("editor.more")
    }
}

// MARK: - iPad and Mac

/// The regular-width editor: filmstrip, photo with a view bar, and an inspector.
struct WorkspaceEditorView: View {
    /// Below this the view bar and toolbar don't fit; see `RootView`.
    static let minimumWidth: CGFloat = 1100

    @Bindable var model: EditorModel
    let filmstrip: Filmstrip.Axis
    let onSelect: (PhotoAsset) -> Void
    @State private var showInspector = true
    @State private var showHistory = false

    var body: some View {
        Group {
            if filmstrip == .vertical {
                HStack(spacing: 0) {
                    Filmstrip(app: model.app, current: model.asset.id, axis: .vertical, onSelect: onSelect)
                        .frame(width: 100)
                    Divider()
                    photoColumn
                }
            } else {
                VStack(spacing: 0) {
                    photoColumn
                    Divider()
                    Filmstrip(app: model.app, current: model.asset.id, axis: .horizontal, onSelect: onSelect)
                        .frame(height: 88)
                }
            }
        }
        .background(Theme.ground)
        .inspector(isPresented: $showInspector) {
            EditorInspector(model: model)
                .inspectorColumnWidth(min: 320, ideal: 340, max: 360)
        }
        .toolbar { toolbar }
        .navigationTitle(model.filename)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay(alignment: .bottom) { ToastView(message: model.app.toast).padding(.bottom, 60) }
        .animation(.default, value: model.app.toast)
        .sheet(isPresented: $model.showExport) { ExportSheet(model: model).frame(minWidth: 420, minHeight: 360) }
        .sheet(isPresented: $model.showPaste) {
            if let clip = model.app.clipboard {
                PasteSheet(clip: clip, count: 1) { groups, mode in model.paste(clip, groups: groups, mode: mode) }
                    .frame(minWidth: 420, minHeight: 480)
            }
        }
    }

    private var photoColumn: some View {
        VStack(spacing: 0) {
            PhotoCanvas(model: model)
            ProgressLine(active: model.isRedecoding || model.phase == .decoding)
            if model.isCropping {
                ScrollView {
                    CropTools(model: model) { model.isCropping = false }
                        .padding()
                        .frame(maxWidth: 640)
                }
                .frame(maxHeight: 300)
            } else if model.isRetouching {
                RetouchTools(model: model) { model.isRetouching = false }
                    .padding()
                    .frame(maxWidth: 640)
            } else {
                viewBar
            }
        }
    }

    private var viewBar: some View {
        ViewThatFits(in: .horizontal) {
            viewBarContent
            ScrollView(.horizontal, showsIndicators: false) { viewBarContent }
        }
        .font(.subheadline)
        .frame(height: 48)
        .background(Theme.panel)
    }

    private var viewBarContent: some View {
        HStack(spacing: 14) {
            Picker("Zoom", selection: Binding(
                get: {
                    switch model.zoom {
                    case .fit: 0
                    case .actual(let scale): abs(scale - 1) < 0.005 ? 1 : -1
                    }
                },
                set: { model.zoom = $0 == 0 ? .fit : .actual(scale: 1) }
            )) {
                Text("Fit").tag(0)
                Text("100%").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
            .accessibilityIdentifier("view.zoom")
            Text("\(Int((model.zoomScale(drawableSize: model.renderer.lastDrawableSize) * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 40, alignment: .leading)
                .accessibilityIdentifier("view.zoomPercent")
            Toggle(isOn: $model.showClipping) { Label("Clipping", systemImage: "exclamationmark.triangle") }
                .toggleStyle(.button)
                .fixedSize()
                .help("Show clipping")
                .accessibilityIdentifier("view.clipping")
            Toggle(isOn: $model.splitView) { Label("Split", systemImage: "rectangle.split.2x1") }
                .toggleStyle(.button)
                .fixedSize()
                .help("Split before/after")
                .accessibilityIdentifier("view.split")
            Button("Crop", systemImage: "crop.rotate") {
                model.zoom = .fit
                model.isCropping = true
            }
            .fixedSize()
            .disabled(model.phase != .ready)
            Button("Retouch", systemImage: "bandage") { model.isRetouching = true }
                .fixedSize()
                .disabled(model.phase != .ready)
                .accessibilityIdentifier("view.retouch")
            Spacer()
            Button("History · \(max(model.history.count - 1, 0))", systemImage: "clock.arrow.circlepath") { showHistory.toggle() }
                .fixedSize()
                .popover(isPresented: $showHistory) {
                    HistoryList(model: model).frame(width: 280, height: 380)
                }
                .accessibilityIdentifier("view.history")
        }
        .padding(.horizontal)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.isRedecoding ? "Re-decoding RAW \(model.info?.decoderVersion ?? "")" : model.filename)
                        .font(.headline)
                        .lineLimit(1)
                    Text(model.badge).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .accessibilityIdentifier("editor.title")
                PreviewStatusIndicator(model: model, showsLabel: true)
                JobTrayPill(jobs: model.app.jobs, alwaysVisible: true)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Copy", systemImage: "doc.on.doc") { model.copyEdits() }
                .disabled(model.recipe.isIdentity)
                .accessibilityIdentifier("toolbar.copy")
            Button("Paste", systemImage: "doc.on.clipboard") { model.showPaste = true }
                .disabled(model.app.clipboard == nil)
                .accessibilityIdentifier("toolbar.paste")
            Toggle(isOn: $model.compare) { Label("Compare", systemImage: "square.split.2x1") }
                .accessibilityIdentifier("toolbar.compare")
            EditorMoreMenu(model: model, pasting: $model.showPaste)
            Button("Export", systemImage: "square.and.arrow.up") { model.showExport = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(model.phase != .ready)
                .accessibilityIdentifier("toolbar.export")
            Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
        }
    }
}

/// Tab picker, histogram and the active panel.
struct EditorInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            // Icons fit six tabs in the inspector's width; the panel headers name them.
            Picker("Tab", selection: $model.tab) {
                ForEach(EditorModel.Tab.allCases) { tab in
                    Image(systemName: tab.systemImage).accessibilityLabel(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])
            Text(model.tab.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 4)
            #if os(macOS)
            HistogramView(histogram: model.histogram)
                .frame(height: 70)
                .padding(.horizontal)
            #endif
            ScrollView {
                if let notice = model.foreignEdit {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                        .padding(10)
                        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
                }
                EditorPanel(model: model, tab: model.tab)
                    .padding(.bottom)
            }
            .id(model.tab)  // Each tab opens at its top.
            .padding(.horizontal)
        }
        .background(Theme.panel)
    }
}

/// History steps, newest first, plus snapshots.
struct HistoryList: View {
    let model: EditorModel

    var body: some View {
        List {
            Section {
                Button("Take snapshot", systemImage: "camera.on.rectangle") { model.takeSnapshot() }
            }
            if !model.snapshots.isEmpty {
                Section("Snapshots") {
                    ForEach(model.snapshots) { step in
                        Button(step.label) { model.jump(to: step) }
                    }
                }
            }
            Section("History") {
                ForEach(Array(model.history.enumerated()).reversed(), id: \.element.id) { index, step in
                    Button {
                        model.jump(to: step)
                    } label: {
                        HStack {
                            Text(step.label).foregroundStyle(index == model.historyIndex ? Theme.accent : Theme.textPrimary)
                            Spacer()
                            if index == model.historyIndex { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Thumbnails of the current album for quick switching.
struct Filmstrip: View {
    enum Axis { case vertical, horizontal }

    let app: AppModel
    let current: String
    let axis: Axis
    let onSelect: (PhotoAsset) -> Void

    var body: some View {
        let size: CGFloat = axis == .vertical ? 84 : 72
        ScrollViewReader { proxy in
            ScrollView(axis == .vertical ? .vertical : .horizontal) {
                if axis == .vertical {
                    LazyVStack(spacing: 6) { tiles(size: size) }.padding(8)
                } else {
                    LazyHStack(spacing: 6) { tiles(size: size) }.padding(8)
                }
            }
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { withAnimation { proxy.scrollTo(current, anchor: .center) } }
        }
        .background(Theme.panel)
    }

    private func tiles(size: CGFloat) -> some View {
        let assets = app.assets
        return ForEach(0..<assets.count, id: \.self) { index in
            let asset = assets[index]
            Button { onSelect(asset) } label: {
                AssetThumbnail(app: app, asset: asset, side: size)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent, lineWidth: asset.id == current ? 2.5 : 0))
            }
            .buttonStyle(.plain)
            .id(asset.id)
            .accessibilityIdentifier("filmstrip.\(index)")
        }
    }
}

/// A small spinner by the title while the on-screen preview is catching up: a
/// quick low-resolution frame during a drag, or detail still decoding when zoomed
/// in. Saving and exporting the full image show in the job tray instead.
struct PreviewStatusIndicator: View {
    let model: EditorModel
    var showsLabel = false

    var body: some View {
        if let status = model.previewStatus {
            let text = switch status {
            case .refining: "Refining preview"
            case .loadingDetail: "Loading detail"
            }
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                if showsLabel {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .help(text)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityIdentifier("editor.previewStatus")
            .transition(.opacity)
        }
    }
}
