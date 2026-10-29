import EditorCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct LightEditorApp: App {
    @State private var app = AppModel(library: AppModel.makeLibrary())

    init() {
        // AI removal is available when the build bundled LaMa (scripts/fetch-models.sh).
        Inpainter.shared.configure(modelURL: Bundle.main.url(forResource: "LaMa", withExtension: "mlmodelc"))
        // "LaMa + diffusion" when the build bundled Stable Diffusion inpainting.
        DiffusionInpainter.shared.configure(.inBundle())
        #if os(iOS)
        // The diffusion models take about 1 GB; let them go under memory pressure.
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            DiffusionInpainter.shared.release()
        }
        #endif
        #if DEBUG
        RemoveDiagnostic.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    await app.start()
                    #if os(macOS) && DEBUG
                    DebugAutomation.start(app: app)
                    #endif
                }
        }
        .commands { EditorCommands(app: app) }
        #if os(macOS)
        .defaultSize(width: 1440, height: 900)
        #endif
    }
}

/// Picks the layout: a navigation stack on iPhone and iPad, a split view on the Mac.
struct RootView: View {
    @Bindable var app: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if app.authorization == .authorized || app.authorization == .limited {
                #if os(macOS)
                MacRootView(app: app)
                #else
                NavigationStack {
                    LibraryView(app: app) { app.editing = $0 }
                        .navigationDestination(isPresented: Binding(
                            get: { app.editing != nil },
                            set: { if !$0 { app.editing = nil } }
                        )) {
                            if let asset = app.editing {
                                editor(for: asset)
                            }
                        }
                }
                #endif
            } else {
                AccessView(app: app)
            }
        }
        .background(Theme.ground)
        .sheet(item: Binding(get: { app.remote.devicesVisible ? nil : app.remote.pending }, set: { if $0 == nil, app.remote.pending != nil { app.remote.respond(allow: false) } })) { pending in
            ConnectionApprovalView(remote: app.remote, pending: pending)
        }
        .onChange(of: scenePhase) { _, phase in
            // Save when the app goes to the background. Not on .inactive: that also
            // fires for Notification Center, and a save can show a Photos prompt.
            if phase == .background { app.activeEditor?.saveIfNeeded() }
            app.remote.scenePhaseChanged(active: phase == .active)
        }
    }

    @ViewBuilder
    private func editor(for asset: PhotoAsset) -> some View {
        EditorContainer(app: app, asset: asset) { model in
            GeometryReader { proxy in
                // Keyed to the window, not the device, so iPad, iPad Split View and iPhone
                // Duo's inner screen each get what fits. The side-by-side workspace needs
                // about 1100 pt for filmstrip, photo and inspector, or 800 pt without the
                // filmstrip in a landscape window (the Duo's inner screen turned sideways).
                // Anything else stacks the photo over the tools; `roomy` is the
                // regular-width version of that (iPad and the Duo's inner screen upright).
                let size = proxy.size
                if sizeClass == .compact {
                    CompactEditorView(model: model)
                } else if size.width >= WorkspaceEditorView.minimumWidth {
                    WorkspaceEditorView(model: model, filmstrip: .vertical) { app.editing = $0 }
                } else if size.width >= WorkspaceEditorView.minimumWidthWithoutFilmstrip, size.width > size.height {
                    WorkspaceEditorView(model: model, filmstrip: nil) { app.editing = $0 }
                } else {
                    CompactEditorView(model: model, roomy: true)
                }
            }
        }
    }
}

/// Menu commands and keyboard shortcuts, routed to the focused editor.
struct EditorCommands: Commands {
    let app: AppModel
    @FocusedValue(\.editor) private var editor

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { editor?.undo() }
                .keyboardShortcut("z")
                .disabled(!(editor?.canUndo ?? false))
            Button("Redo") { editor?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(editor?.canRedo ?? false))
        }
        CommandMenu("Photo") {
            Button("Copy Edits") { editor?.copyEdits() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button("Paste Edits…") { editor?.showPaste = true }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(editor == nil || app.clipboard == nil)
            Button("Match Previous") { editor?.matchPrevious() }
                .disabled(editor == nil || app.previousEdit == nil)
            Divider()
            Button("Before / After") { editor?.compare.toggle() }
                .keyboardShortcut("\\", modifiers: [])
                .disabled(editor == nil)
            Button("Fit / 100%") {
                guard let editor else { return }
                if case .fit = editor.zoom { editor.zoom = .actual(scale: 1) } else { editor.zoom = .fit }
            }
            .keyboardShortcut("z", modifiers: [])
            .disabled(editor == nil)
            Button("Show Clipping") { editor?.showClipping.toggle() }
                .keyboardShortcut("j", modifiers: [])
                .disabled(editor == nil)
            Divider()
            Button("Previous Photo") { app.step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(app.editing == nil)
            Button("Next Photo") { app.step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(app.editing == nil)
            Divider()
            Button("Export…") { editor?.showExport = true }
                .keyboardShortcut("e")
                .disabled(editor == nil)
        }
    }
}
