import CoreImage
import Foundation
import Testing
@testable import EditorCore

@Suite struct PhotosCopyTests {
    @Test func recipeFallsBackToTheDefaultForWhatItDoesNotSet() {
        let fallback = PhotosCopy(maxMegapixels: 24, quality: 0.8)
        var recipe = Recipe()
        #expect(recipe.photosCopy(fallback: fallback) == fallback)
        #expect(!recipe.hasOwnPhotosCopy)
        recipe.setScalar(.photosMaxMegapixels, 12, at: testClock.now())
        #expect(recipe.photosCopy(fallback: fallback) == PhotosCopy(maxMegapixels: 12, quality: 0.8))
        // An explicit 0 is full size, even when the default is smaller.
        recipe.setScalar(.photosMaxMegapixels, 0, at: testClock.now())
        recipe.setScalar(.photosQuality, 0.95, at: testClock.now())
        #expect(recipe.photosCopy(fallback: fallback) == PhotosCopy(maxMegapixels: 0, quality: 0.95))
        #expect(recipe.hasOwnPhotosCopy)
        recipe.setScalar(.photosQuality, 0.1, at: testClock.now())
        #expect(recipe.photosCopy(fallback: fallback).quality == PhotosCopy.qualityRange.lowerBound, "clamped")
    }

    @Test func survivesEncodeAndDecode() throws {
        var recipe = Recipe()
        recipe.setScalar(.photosMaxMegapixels, 16, at: testClock.now())
        recipe.setScalar(.photosQuality, 0.75, at: testClock.now())
        let decoded = try RecipeCodec.decode(RecipeCodec.encode(recipe))
        #expect(decoded == recipe)
        #expect(decoded.photosCopy(fallback: .full) == PhotosCopy(maxMegapixels: 16, quality: 0.75))
    }

    @Test func pastesOnlyWhenTicked() {
        var source = Recipe()
        source.setScalar(.exposure, 1, at: testClock.now())
        source.setScalar(.photosMaxMegapixels, 12, at: testClock.now())
        source.setScalar(.photosQuality, 0.8, at: testClock.now())
        let clip = RecipeClip(recipe: source, sourceName: "a", sourceDefaults: .generic)
        #expect(!PasteGroup.defaultSelection.contains(.photosCopy))
        #expect(Set(PasteGroup.photosCopy.keys) == [.photosMaxMegapixels, .photosQuality])

        let look = Recipe().pasting(clip, groups: PasteGroup.defaultSelection, mode: .set, targetDefaults: .generic, stamp: testClock.now())
        #expect(look.scalar(.exposure) == 1)
        #expect(!look.hasOwnPhotosCopy)

        for mode in PasteMode.allCases {
            var target = Recipe()
            target.setScalar(.photosMaxMegapixels, 24, at: testClock.now())
            let pasted = target.pasting(clip, groups: [.photosCopy], mode: mode, targetDefaults: .generic, stamp: testClock.now())
            #expect(pasted.photosCopy(fallback: .full) == PhotosCopy(maxMegapixels: 12, quality: 0.8), "\(mode) copies the values as they are")
            #expect(pasted.scalar(.exposure) == nil)
        }
    }

    @Test func outputSize() {
        let full = CGSize(width: 9504, height: 6336)
        #expect(PhotosCopy.full.outputSize(full: full) == full)
        let twelve = PhotosCopy(maxMegapixels: 12).outputSize(full: full)
        #expect(abs(twelve.width * twelve.height / 1e6 - 12) < 0.1)
        #expect(abs(twelve.width / twelve.height - 1.5) < 0.01)
        #expect(PhotosCopy(maxMegapixels: 100).outputSize(full: full) == full, "never larger than the photo")
    }

    @Test func savesAreCappedToTheMaximumSize() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "big.jpg")
        try #require(RenderContext.shared.jpegRepresentation(of: solid(0.5, 0.4, 0.3, size: 2000), colorSpace: RenderContext.sRGB)).write(to: url)
        let decoder = RawDecoder(cache: DecodeCache(directory: nil))
        func size(_ recipe: Recipe, _ copy: PhotosCopy) async throws -> CGSize {
            let data = try await Exporter.render(source: PhotoSource(url: url), recipe: recipe, luts: nil, options: copy.exportOptions(), decoder: decoder)
            return try #require(CIImage(data: data)).extent.size
        }
        #expect(try await size(Recipe(), .full) == CGSize(width: 2000, height: 2000))
        let capped = try await size(Recipe(), PhotosCopy(maxMegapixels: 1))
        #expect(abs(capped.width - 1000) <= 1 && abs(capped.height - 1000) <= 1)
        // The cap applies to the cropped size: half the width is 2 MP, so 1 MP is 707 × 1414.
        var cropped = Recipe()
        cropped.set(.crop, .crop(CropGeometry(rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1))), at: testClock.now())
        let croppedSize = try await size(cropped, PhotosCopy(maxMegapixels: 1))
        #expect(abs(croppedSize.width - 707) <= 2 && abs(croppedSize.height - 1414) <= 2)
        #expect(try await size(Recipe(), PhotosCopy(maxMegapixels: 10)) == CGSize(width: 2000, height: 2000), "never upscaled")
    }
}
