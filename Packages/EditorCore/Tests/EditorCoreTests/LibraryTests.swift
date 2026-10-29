import CoreImage
import Foundation
import Testing
@testable import EditorCore

/// Writes `count` small JPEGs into a fresh folder library.
func makeFolderLibrary(count: Int) throws -> (FolderLibrary, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in 0..<count {
        let shade = 0.2 + 0.6 * Double(index) / Double(max(count - 1, 1))
        let image = solid(shade, 0.3, 0.2, size: 48)
        let jpeg = try #require(RenderContext.shared.jpegRepresentation(of: image, colorSpace: RenderContext.sRGB))
        try jpeg.write(to: directory.appending(path: String(format: "IMG_%04d.jpg", index)))
    }
    return (FolderLibrary(directory: directory), directory)
}

@Suite struct BulkEditorTests {
    @Test func pastesToManyPhotos() async throws {
        let (library, _) = try makeFolderLibrary(count: 12)
        let assets = await library.assets(in: .recents)
        var source = Recipe()
        source.setScalar(.exposure, 0.5, at: testClock.now())
        source.setScalar(.vibrance, 25, at: testClock.now())
        source.set(.crop, .crop(CropGeometry(rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5))), at: testClock.now())
        let clip = RecipeClip(recipe: source, sourceName: "IMG_4821", sourceDefaults: .generic)

        let thumbnails = Counter()
        let saved = try await BulkEditor.apply(
            .paste(clip, groups: PasteGroup.defaultSelection, mode: .set),
            to: (0..<assets.count).map { assets[$0] },
            library: library, luts: nil, clock: testClock, format: .jpeg,
            progress: { _ in }, thumbnail: { _, _ in thumbnails.increment() }
        )
        #expect(saved == 12)
        #expect(thumbnails.value == 12, "every photo gets a thumbnail before the full renders")
        for index in 0..<assets.count {
            guard case .ours(let recipe) = await library.storedEdit(for: assets[index]) else {
                Issue.record("photo \(index) has no edit")
                continue
            }
            #expect(recipe.scalar(.exposure) == 0.5)
            #expect(recipe[.crop] == nil, "crop is per photo and off by default")
        }
    }

    @Test func adjustModeStacksOnExistingEdits() async throws {
        let (library, _) = try makeFolderLibrary(count: 2)
        let assets = await library.assets(in: .recents)
        let first = try await library.beginEditing(assets[0]) { _ in }
        var existing = Recipe(decoder: .none)
        existing.setScalar(.exposure, 1, at: testClock.now())
        try await library.save(first, recipe: existing, rendered: Data([0]), format: .jpeg)

        try await BulkEditor.apply(
            .values([.exposure: 0.25], mode: .adjust),
            to: [assets[0], assets[1]], library: library, luts: nil, clock: testClock, format: .jpeg,
            progress: { _ in }, thumbnail: { _, _ in }
        )
        guard case .ours(let a) = await library.storedEdit(for: assets[0]),
              case .ours(let b) = await library.storedEdit(for: assets[1]) else {
            Issue.record("missing edits")
            return
        }
        #expect(a.scalar(.exposure) == 1.25)
        #expect(b.scalar(.exposure) == 0.25)
    }

    @Test func cancels() async throws {
        let (library, _) = try makeFolderLibrary(count: 30)
        let assets = await library.assets(in: .recents)
        let task = Task {
            try await BulkEditor.apply(
                .reset, to: (0..<assets.count).map { assets[$0] }, library: library, luts: nil, clock: testClock,
                progress: { _ in }, thumbnail: { _, _ in }
            )
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@Suite struct ImporterTests {
    @Test func pairsRawAndJpegByName() {
        let urls = ["DSCF2030.RAF", "DSCF2030.JPG", "DSC04321.ARW", "IMG_1.HEIC", "notes.txt"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        let groups = PhotoImporter.groups(for: urls)
        #expect(groups.count == 3)
        let fuji = groups.first { $0.primary.lastPathComponent == "DSCF2030.JPG" }
        #expect(fuji?.rawAlternate?.lastPathComponent == "DSCF2030.RAF")
        let sony = groups.first { $0.primary.lastPathComponent == "DSC04321.ARW" }
        #expect(sony?.rawAlternate == nil)
    }

    @Test func importsIntoFolderLibrary() async throws {
        let (source, sourceDirectory) = try makeFolderLibrary(count: 3)
        _ = source
        let files = try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jpg" }
        let (target, _) = try makeFolderLibrary(count: 0)
        let count = try await PhotoImporter.importFiles(files, into: target) { _ in }
        #expect(count == 3)
        #expect(await target.assets(in: .recents).count == 3)
    }
}
