import EditorCore
import SwiftUI

#if os(macOS)
/// The Mac window: sidebar (library, albums, history), then the grid or the editor.
struct MacRootView: View {
    @Bindable var app: AppModel
    @FocusedValue(\.editor) private var editor

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { app.album }, set: { if let album = $0 { app.album = album; app.editing = nil } })) {
                Section("Library") {
                    ForEach(app.albums.filter { if case .user = $0 { false } else { true } }) { album in
                        Label(album.title, systemImage: album.systemImage).tag(album)
                    }
                }
                let userAlbums = app.albums.filter { if case .user = $0 { true } else { false } }
                if !userAlbums.isEmpty {
                    Section("Albums") {
                        ForEach(userAlbums) { album in
                            Label(album.title, systemImage: album.systemImage).tag(album)
                        }
                    }
                }
                if let editor {
                    Section("History") {
                        Button("Snapshot", systemImage: "camera.on.rectangle") { editor.takeSnapshot() }
                            .buttonStyle(.plain)
                        ForEach(editor.snapshots) { step in
                            Button(step.label, systemImage: "bookmark") { editor.jump(to: step) }
                                .buttonStyle(.plain)
                        }
                        ForEach(Array(editor.history.enumerated()).reversed(), id: \.element.id) { index, step in
                            Button(step.label) { editor.jump(to: step) }
                                .buttonStyle(.plain)
                                .foregroundStyle(index == editor.historyIndex ? Theme.accent : Theme.textPrimary)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            NavigationStack {
                if let asset = app.editing {
                    EditorContainer(app: app, asset: asset) { model in
                        WorkspaceEditorView(model: model, filmstrip: .horizontal) { app.editing = $0 }
                    }
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button("Library", systemImage: "square.grid.3x3") { app.editing = nil }
                                .accessibilityIdentifier("editor.back")
                        }
                    }
                } else {
                    LibraryView(app: app) { app.editing = $0 }
                }
            }
        }
    }
}
#endif
