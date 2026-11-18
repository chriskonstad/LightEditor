import Foundation
import Testing
@testable import EditorCore

@Suite struct SyncedFolderTests {
    func temporary() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "synced-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func writesReadsListsAndDeletes() throws {
        let folder = SyncedFolder(directory: temporary())
        try folder.write(Data("a".utf8), to: "one.json")
        try folder.write(Data("b".utf8), to: "two.cube")
        #expect(folder.files(withExtension: "json") == ["one.json"])
        #expect(folder.read("one.json") == Data("a".utf8))
        try folder.delete("one.json")
        #expect(folder.files(withExtension: "json").isEmpty)
        #expect(folder.read("one.json") == nil)
    }

    @Test func movingBringsFilesAlongWithoutOverwriting() throws {
        let local = SyncedFolder(directory: temporary())
        try local.write(Data("mine".utf8), to: "a.json")
        try local.write(Data("old".utf8), to: "shared.json")
        let cloud = temporary()
        let other = SyncedFolder(directory: cloud)
        try other.write(Data("from the other device".utf8), to: "shared.json")

        local.move(to: cloud)
        #expect(local.url.standardizedFileURL == cloud.standardizedFileURL)
        #expect(Set(local.files(withExtension: "json")) == ["a.json", "shared.json"])
        #expect(local.read("shared.json") == Data("from the other device".utf8), "what's already in iCloud wins")
        #expect(local.read("a.json") == Data("mine".utf8))
    }

    @Test func presetsFollowTheirFolder() throws {
        let store = PresetStore(directory: temporary())
        let preset = Preset(name: "Warm", groups: [.whiteBalance], params: [.temperature: .scalar(10)])
        try store.save(preset)
        let cloud = temporary()
        store.folder.move(to: cloud)
        #expect(store.load() == [preset])
        #expect(PresetStore(directory: cloud).load() == [preset], "another device sees it")
    }
}
