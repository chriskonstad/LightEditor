import Foundation
import Testing
@testable import EditorCore

@Suite struct SonyLooksTests {
    /// A little-endian TIFF with IFD0 → Exif IFD → a "SONY DSC" maker note holding the given tags.
    private func makeARW(look: String, integers: [UInt16: [Int32]]) -> Data {
        var data = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: UInt32) { u16(tag); u16(type); u32(count); u32(value) }

        data.append(contentsOf: Array("II".utf8)); u16(42); u32(8)
        // IFD0 at 8: one entry pointing to the Exif IFD at 26.
        u16(1); entry(0x8769, 4, 1, 26); u32(0)
        // Exif IFD at 26: the maker note at 44.
        let makerNoteStart: UInt32 = 44
        u16(1); entry(0x927C, 7, 1024, makerNoteStart); u32(0)
        // Maker note: header, then an IFD whose out-of-line values follow it.
        data.append(contentsOf: Array("SONY DSC ".utf8) + [0, 0, 0])
        let tags = integers.keys.sorted()
        let ifdStart = Int(makerNoteStart) + 12
        var extra = Data()
        let extraStart = ifdStart + 2 + (tags.count + 1) * 12 + 4
        u16(UInt16(tags.count + 1))
        let lookBytes = Array(look.utf8) + [0]
        if lookBytes.count <= 4 {
            // TIFF keeps values of 4 bytes or fewer inline.
            let padded = lookBytes + Array(repeating: 0, count: 4 - lookBytes.count)
            entry(0xb020, 2, UInt32(lookBytes.count), padded.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        } else {
            entry(0xb020, 2, UInt32(lookBytes.count), UInt32(extraStart + extra.count)); extra.append(contentsOf: lookBytes)
        }
        for tag in tags {
            let values = integers[tag]!
            if values.count == 1 {
                entry(tag, 9, 1, UInt32(bitPattern: values[0]))
            } else {
                entry(tag, 9, UInt32(values.count), UInt32(extraStart + extra.count))
                for value in values { withUnsafeBytes(of: value.littleEndian) { extra.append(contentsOf: $0) } }
            }
        }
        u32(0)
        data.append(extra)
        return data
    }

    @Test func readsLookAdjustmentsAndWhiteBalanceShift() throws {
        let data = makeARW(look: "FL", integers: [0x2004: [2], 0x2034: [3], 0x2033: [-1], 0x2026: [1500, -500]])
        let notes = try #require(SonyMakerNote(data: data))
        let settings = try #require(SonyLooks.settings(from: notes))
        #expect(settings.look == "FL")
        #expect(settings.contrast == 2)
        #expect(settings.fade == 3)
        #expect(settings.highlights == -1)
        #expect(settings.amberBlue == 1.5)
        #expect(settings.greenMagenta == -0.5)
        #expect(settings.whiteBalanceShift == "A+1.5 G0.5")
        #expect(settings.summary == "FL · Contrast +2 · Highlights -1 · Fade 3 · WB A+1.5 G0.5")
    }

    @Test func cameraPresetAddsAdjustmentsToTheLook() throws {
        var settings = SonyLooks.CameraSettings(look: "FL")
        settings.contrast = 2
        settings.fade = 3
        settings.amberBlue = 1.5
        let fl = try #require(SonyLooks.preset(code: "FL"))
        let preset = try #require(SonyLooks.cameraPreset(for: settings))
        // FL's contrast 16, +2 steps × 5, −3 fade × 2.
        #expect(preset.params[.contrast] == .scalar(16 + 10 - 6))
        #expect(preset.params[.blacks] == .scalar(6 + 9))
        #expect(preset.params[.toneCurve] == fl.params[.toneCurve])
        #expect(preset.params[.temperature] == nil, "the shift is already in the as-shot white balance")
        #expect(preset.name == "FL · Contrast +2 · Fade 3 · WB A+1.5")
        #expect(preset.id == SonyLooks.cameraPreset(for: settings)?.id, "stable, so the editor can match it")
    }

    private func flCamera() -> SonyLooks.CameraSettings {
        var settings = SonyLooks.CameraSettings(look: "FL")
        settings.contrast = 2
        settings.fade = 3
        settings.amberBlue = 1.5
        return settings
    }

    @Test func cameraLookKeysAreInDefaultPasteGroups() throws {
        let preset = try #require(SonyLooks.cameraPreset(for: flCamera()))
        let groups = Set(try preset.params.keys.map { key in try #require(ParamCatalog.all.first { $0.key == key }?.group) })
        #expect(groups == [.light, .color, .grade])
        #expect(groups.isSubset(of: PasteGroup.defaultSelection), "Copy edits → Paste carries the whole look by default")
    }

    @Test func pastingCameraLookFiltersByGroup() throws {
        let preset = try #require(SonyLooks.cameraPreset(for: flCamera()))
        let applied = Recipe().applying(preset, amount: 1, defaults: .generic, stamp: testClock.now())
        let clip = RecipeClip(recipe: applied, sourceName: "DSC0001", sourceDefaults: .generic)

        let all = Recipe().pasting(clip, groups: PasteGroup.defaultSelection, mode: .set, targetDefaults: .generic, stamp: testClock.now())
        for key in preset.params.keys { #expect(all[key] == applied[key], "\(key.rawValue) pastes") }

        let colorOnly = Recipe().pasting(clip, groups: [.color], mode: .set, targetDefaults: .generic, stamp: testClock.now())
        #expect(colorOnly.scalar(.saturation) == applied.scalar(.saturation))
        #expect(colorOnly[.hsl(.green, .hue)] == applied[.hsl(.green, .hue)])
        #expect(colorOnly.scalar(.contrast) == nil, "Light isn't pasted")
        #expect(colorOnly[.toneCurve] == nil)
        #expect(colorOnly[.gradeWheel(.shadows)] == nil, "Color grading isn't pasted")
    }

    @Test func bulkCameraLookUsesEachPhotosOwnSettings() throws {
        var fl = SourceInfo(isRAW: true, nativeSize: .zero, decoderVersion: "9", supportedDecoderVersions: ["9"], defaults: .generic)
        fl.sonyLook = flCamera()
        var vivid = fl
        vivid.sonyLook = SonyLooks.CameraSettings(look: "VV")
        let plain = SourceInfo(isRAW: true, nativeSize: .zero, decoderVersion: "9", supportedDecoderVersions: ["9"], defaults: .generic)
        var fuji = plain
        fuji.filmSimulation = "Classic Chrome"

        var base = Recipe()
        base.setScalar(.temperature, 5200, at: testClock.now())
        let change = BulkChange.cameraLook(amount: 1)
        let flResult = change.apply(to: base, info: fl, stamp: testClock.now())
        let vividResult = change.apply(to: base, info: vivid, stamp: testClock.now())
        #expect(flResult.scalar(.contrast) == SonyLooks.cameraPreset(for: flCamera())?.params[.contrast].flatMap { if case .scalar(let v) = $0 { v } else { nil } })
        #expect(vividResult.scalar(.saturation) == 24, "VV's own saturation")
        #expect(flResult.scalar(.temperature) == 5200, "white balance isn't part of the look")
        #expect(change.apply(to: base, info: plain, stamp: testClock.now()) == base, "no camera look: unchanged")
        #expect(change.apply(to: base, info: fuji, stamp: testClock.now()).scalar(.saturation) == FilmSimulations.preset(named: "Classic Chrome")?.params[.saturation].flatMap { if case .scalar(let v) = $0 { v } else { nil } })
    }

    @Test func mapsCreativeStyleNames() {
        #expect(SonyLooks.code(forCreativeStyle: "Standard") == "ST")
        #expect(SonyLooks.code(forCreativeStyle: "Vivid") == "VV")
        #expect(SonyLooks.code(forCreativeStyle: "BW") == "BW")
        #expect(SonyLooks.code(forCreativeStyle: "VV2") == "VV2")
        #expect(SonyLooks.code(forCreativeStyle: "Autumnleaves") == nil)
        #expect(Set(SonyLooks.presets.map(\.name)).count == SonyLooks.presets.count)
    }

    @Test func ignoresOtherFiles() throws {
        #expect(SonyMakerNote(data: Data("not a tiff".utf8)) == nil)
        let url = FileManager.default.temporaryDirectory.appending(path: "photo.jpg")
        try Data([0xFF, 0xD8]).write(to: url)
        #expect(SonyLooks.read(fileAt: url) == nil)
    }

    /// Reads a real ARW. Make one from any Sony ARW with
    /// `exiftool -n -Sony:CreativeStyle=FL -Sony:Contrast=2 -Sony:Fade=3 -Sony:Highlights=-1 -Sony:WBShiftAB_GM_Precise="1500 -500" file.ARW`
    /// and set SONY_LOOK_SAMPLE to its path.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SONY_LOOK_SAMPLE"] != nil))
    func readsARWWrittenByExiftool() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SONY_LOOK_SAMPLE"]!)
        let settings = try #require(SonyLooks.read(fileAt: url))
        #expect(settings.look == "FL")
        #expect(settings.contrast == 2)
        #expect(settings.fade == 3)
        #expect(settings.highlights == -1)
        #expect(settings.whiteBalanceShift == "A+1.5 G0.5")
    }
}
