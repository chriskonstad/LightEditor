import EditorCore
import SwiftUI

/// A thumbnail from the library, or the pending render from a running bulk edit.
struct AssetThumbnail: View {
    let app: AppModel
    let asset: PhotoAsset
    let side: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        // The color sets the size; the image fills it without ever growing the
        // view (and its hit area) past the cell.
        Theme.panelRaised
            .overlay {
                if let pending = app.pendingThumbnails[asset.id] {
                    Image(decorative: pending, scale: 1).resizable().scaledToFill()
                } else if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if app.pendingThumbnails[asset.id] != nil {
                    ProgressView().controlSize(.small).padding(4)
                }
            }
            .clipped()
            .contentShape(Rectangle())
        .task(id: "\(asset.id)-\(app.libraryVersion)") {
            let pixels = side * displayScale
            image = await app.library.thumbnail(for: asset, pixelSize: CGSize(width: pixels, height: pixels))
        }
    }
}

/// The library grid with album switching, multi-select and bulk paste.
struct LibraryView: View {
    @Bindable var app: AppModel
    let onOpen: (PhotoAsset) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var pasting = false
    @State private var adjusting = false
    @State private var presetPicking = false
    @State private var importing = false
    @State private var showingDevices = false
    @State private var showingSettings = false

    private var columns: [GridItem] {
        if sizeClass == .compact {
            return Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
        }
        return [GridItem(.adaptive(minimum: 150), spacing: 2)]
    }

    var body: some View {
        ScrollView {
            RemoteBanner(remote: app.remote)
            if let clip = app.clipboard {
                HStack {
                    Label("Copied: \((clip.sourceName as NSString).deletingPathExtension)", systemImage: "doc.on.clipboard")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.panelRaised, in: Capsule())
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityIdentifier("library.copiedChip")
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                // Captured, so a grid cell built for the old list never indexes a new,
                // shorter one (e.g. after switching libraries).
                let assets = app.assets
                ForEach(0..<assets.count, id: \.self) { index in
                    let asset = assets[index]
                    tile(asset, index: index)
                }
            }
            if app.assets.count == 0 {
                ContentUnavailableView("No photos", systemImage: "photo.on.rectangle", description: Text("Import RAW photos into \(app.library.displayName) to edit them here."))
                    .padding(.top, 80)
            }
        }
        .background(Theme.ground)
        .navigationTitle(selecting ? (selection.isEmpty ? "Select Photos" : "\(selection.count) Selected") : app.album.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar }
        .sheet(isPresented: $showingDevices) { DevicesSheet(remote: app.remote) }
        .sheet(isPresented: $showingSettings) { SettingsSheet() }
        .safeAreaInset(edge: .bottom) {
            if selecting { selectionBar }
        }
        .overlay(alignment: .bottom) { ToastView(message: app.toast).padding(.bottom, 80) }
        .animation(.default, value: app.toast)
        .sheet(isPresented: $pasting) {
            if let clip = app.clipboard {
                PasteSheet(clip: clip, count: selection.count) { groups, mode in
                    app.bulkApply(.paste(clip, groups: groups, mode: mode), to: selectedAssets, label: "Pasting edits to \(selection.count) photos")
                    endSelection()
                }
                .frame(minWidth: 420, minHeight: 480)
            }
        }
        .sheet(isPresented: $adjusting) {
            BulkAdjustSheet(count: selection.count) { values, mode in
                app.bulkApply(.values(values, mode: mode), to: selectedAssets, label: "Editing \(selection.count) photos")
                endSelection()
            }
            .frame(minWidth: 420, minHeight: 560)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty { app.importFiles(urls) }
        }
        .confirmationDialog("Apply preset", isPresented: $presetPicking) {
            ForEach(app.presets) { preset in
                Button(preset.name) {
                    app.bulkApply(.preset(preset, amount: 1), to: selectedAssets, label: "Applying “\(preset.name)” to \(selection.count) photos")
                    endSelection()
                }
            }
        }
    }

    private var selectedAssets: [PhotoAsset] {
        let assets = app.assets
        return (0..<assets.count).map { assets[$0] }.filter { selection.contains($0.id) }
    }

    private func endSelection() {
        selecting = false
        selection = []
    }

    private func tile(_ asset: PhotoAsset, index: Int) -> some View {
        let selected = selection.contains(asset.id)
        return Button {
            if selecting {
                if selected { selection.remove(asset.id) } else { selection.insert(asset.id) }
            } else {
                onOpen(asset)
            }
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { AssetThumbnail(app: app, asset: asset, side: 140) }
                .clipped()
                .contentShape(Rectangle())
                .overlay(alignment: .bottomTrailing) {
                    if selecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(selected ? Theme.onAccent : .white, selected ? Theme.accent : .clear)
                            .shadow(radius: 2)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if asset.hasAdjustments && !selecting {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption2)
                            .padding(4)
                            .background(.black.opacity(0.45), in: Circle())
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                }
                .opacity(selecting && !selected ? 0.85 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo \(index + 1)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("library.photo.\(index)")
        .contextMenu {
            Button("Open", systemImage: "slider.horizontal.3") { onOpen(asset) }
            if let clip = app.clipboard {
                Button("Paste edits", systemImage: "doc.on.clipboard") {
                    app.bulkApply(.paste(clip, groups: PasteGroup.defaultSelection, mode: .set), to: [asset], label: "Pasting edits")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { endSelection() }
                    .accessibilityIdentifier("library.cancelSelect")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(selection.count == app.assets.count ? "Deselect All" : "Select All") {
                    if selection.count == app.assets.count {
                        selection = []
                    } else {
                        let assets = app.assets
                        selection = Set((0..<assets.count).map { assets[$0].id })
                    }
                }
                .accessibilityIdentifier("library.selectAll")
            }
        } else {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) { albumMenu }
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    .accessibilityIdentifier("library.settings")
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                JobTrayPill(jobs: app.jobs)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Devices", systemImage: "ipad.and.iphone") { showingDevices = true }
                    .accessibilityIdentifier("library.devices")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Import", systemImage: "square.and.arrow.down.on.square") { importing = true }
                    .disabled(app.remoteLibrary != nil)
                    .accessibilityIdentifier("library.import")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Select") { selecting = true }
                    .disabled(app.assets.count == 0)
                    .accessibilityIdentifier("library.select")
            }
        }
    }

    private var albumMenu: some View {
        Menu {
            Picker("Album", selection: $app.album) {
                ForEach(app.albums) { album in
                    Label(album.title, systemImage: album.systemImage).tag(album)
                }
            }
        } label: {
            Label("Albums", systemImage: "rectangle.stack")
        }
        .accessibilityIdentifier("library.albums")
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button("Paste", systemImage: "doc.on.clipboard") { pasting = true }
                .disabled(selection.isEmpty || app.clipboard == nil)
                .accessibilityIdentifier("library.paste")
            Button("Adjust", systemImage: "slider.horizontal.3") { adjusting = true }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("library.adjust")
            Button("Preset", systemImage: "camera.filters") { presetPicking = true }
                .disabled(selection.isEmpty)
            Spacer()
            Button("Reset", systemImage: "arrow.counterclockwise", role: .destructive) {
                app.bulkApply(.reset, to: selectedAssets, label: "Resetting \(selection.count) photos")
                endSelection()
            }
            .disabled(selection.isEmpty)
        }
        .labelStyle(.titleAndIcon)
        .padding()
        .background(.bar)
    }
}

/// First-run access request.
struct AccessView: View {
    let app: AppModel
    @State private var showingDevices = false
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
            Text("LightEditor").font(.largeTitle.bold())
            Text("Your photos stay in \(app.library.displayName). Edits are saved non-destructively alongside the originals, and iCloud Photos syncs them to your other devices.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: 420)
            if app.authorization == .denied {
                Text("Access is turned off. Allow it in Settings › Privacy › Photos.")
                    .foregroundStyle(.red)
            } else {
                Button("Allow Photos Access") { Task { await app.requestAccess() } }
                    .buttonStyle(AccentButtonStyle())
                    .accessibilityIdentifier("access.allow")
            }
            Button("Edit Photos on Another Device…", systemImage: "ipad.and.iphone") { showingDevices = true }
                .accessibilityIdentifier("access.devices")
            Button("About and Licenses") { showingSettings = true }
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("access.settings")
        }
        .sheet(isPresented: $showingDevices) { DevicesSheet(remote: app.remote) }
        .sheet(isPresented: $showingSettings) { SettingsSheet() }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }
}
