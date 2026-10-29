import CoreImage
import Foundation
import Testing
@testable import EditorCore

@Suite struct AutoStraightenModelTests {
    /// A minimal Fuji maker note with one RollAngle entry of `numerator / 10`.
    func fujiNote(_ numerator: Int32) -> Data {
        var bytes = [UInt8]("junkFUJIFILM".utf8) + [0x0C, 0, 0, 0]
        // IFD at offset 12 from "FUJIFILM": 1 entry, tag 0x144D, SRATIONAL, count 1, value at 30.
        bytes += [1, 0, 0x4D, 0x14, 10, 0, 1, 0, 0, 0, 30, 0, 0, 0]
        bytes += [0, 0, 0, 0]  // next IFD
        func le(_ v: Int32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        bytes += le(numerator) + le(10)
        return Data(bytes)
    }

    @Test func readsFujiRoll() {
        #expect(CameraLevel.fujiRoll(in: fujiNote(15)) == 1.5)
        #expect(CameraLevel.fujiRoll(in: fujiNote(-23)) == -2.3)
        #expect(CameraLevel.fujiRoll(in: Data("no maker note here".utf8)) == nil)
    }

    @Test func pastingFindsTheLevelAgainAndKeepsTheTweak() {
        var source = Recipe()
        var geometry = CropGeometry(angle: 2.5, auto: AutoStraighten(method: .horizon, detected: 2, tweak: 0))
        geometry.setAngle(2.5)
        #expect(geometry.auto?.tweak == 0.5)
        source.set(.crop, .crop(geometry), at: testClock.now())
        let clip = RecipeClip(recipe: source, sourceName: "a", sourceDefaults: .generic)
        let pasted = Recipe().pasting(clip, groups: [.crop], mode: .set, targetDefaults: .generic, stamp: testClock.now())
        guard case .crop(let result)? = pasted[.crop] else { Issue.record("no crop"); return }
        #expect(result.auto?.isResolved == false)
        #expect(result.auto?.tweak == 0.5)
        #expect(result.angle == 2.5, "the angle stays as the fallback")
    }

    @Test func roundTripsThroughTheCodec() throws {
        var recipe = Recipe()
        recipe.set(.crop, .crop(CropGeometry(angle: 1, auto: AutoStraighten(method: .camera, detected: 1.2, tweak: -0.2))), at: testClock.now())
        let decoded = try RecipeCodec.decode(RecipeCodec.encode(recipe))
        #expect(decoded[.crop] == recipe[.crop])
    }

    @Test func unresolvedWithNothingFoundFallsBackToTheAngle() async {
        var recipe = Recipe()
        recipe.set(.crop, .crop(CropGeometry(angle: 3, auto: AutoStraighten(method: nil, detected: nil, tweak: 0))), at: testClock.now())
        // A flat gray image has no horizon, and a non-RAW source has no camera level.
        let image = solid(0.5, 0.5, 0.5, size: 400)
        let resolved = await AutoStraightener.resolve(recipe, source: PhotoSource(url: URL(fileURLWithPath: "/tmp/none.jpg")), image: image, stamp: testClock.now())
        guard case .crop(let geometry)? = resolved?[.crop] else { Issue.record("not resolved"); return }
        #expect(geometry.auto == nil)
        #expect(geometry.angle == 3)
    }
}

/// Runs on the real X-T5 sunset. Set EDITORCORE_RAW_FIXTURES to run.
@Suite(.serialized) struct AutoStraightenFixtureTests {
    @Test(.enabled(if: VisionMaskTests.fixture("DSCF2030") != nil)) func levelsTheSunset() async throws {
        let url = VisionMaskTests.fixture("DSCF2030")!
        let decoder = RawDecoder(cache: DecodeCache(directory: nil))
        let base = try await decoder.decode(PhotoSource(url: url), rawStage: RawStageParams(), longEdge: 1600).image
        let roll = try #require(CameraLevel.roll(fileAt: url))
        let angle = try #require(await AutoStraightener.horizon(in: base))
        print("STRAIGHTEN fuji roll \(roll) horizon \(angle)")
        #expect(abs(roll - angle) < 1.0, "the camera's level agrees with the horizon")

        func turned(_ image: CIImage, by degrees: Double) -> CIImage {
            var recipe = Recipe()
            recipe.set(.crop, .crop(CropGeometry(angle: degrees)), at: testClock.now())
            return GradeGraph.apply(recipe, to: image, inputs: GradeInputs(defaults: .generic))
        }
        // Turned by `tilt`, the photo needs about its own correction minus the tilt.
        for tilt in [-5.0, 3.0, 8.0] {
            let found = await AutoStraightener.horizon(in: turned(base, by: tilt))
            print("STRAIGHTEN tilt \(tilt) -> \(String(describing: found))")
            #expect(abs((found ?? 99) - (angle - tilt)) < 0.5)
        }
        // Applying the found angle leaves it level.
        let after = await AutoStraightener.horizon(in: turned(base, by: angle))
        print("STRAIGHTEN after \(String(describing: after))")
        #expect(abs(after ?? 99) < 0.5)
    }
}
