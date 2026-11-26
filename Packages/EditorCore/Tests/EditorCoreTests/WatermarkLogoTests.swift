import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EditorCore

/// Logo watermarks: the store, the recipe value, fitting and drawing, and sending
/// the file along with renders on another device.
@Suite struct WatermarkLogoTests {
    /// A white 2:1 logo on transparency, as PNG.
    static func pngLogo(width: Int = 200, height: Int = 100) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: RenderContext.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A vector logo (3:1 unless asked): a white rectangle filling the page, as PDF.
    static func pdfLogo(width: Int = 300) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: 100)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    static func store() -> LUTStore {
        let root = FileManager.default.temporaryDirectory.appending(path: "logos-\(UUID().uuidString)")
        return LUTStore(directory: root.appending(path: "LUTs"), logos: WatermarkLogoStore(directory: root.appending(path: "Watermarks")))
    }

    static func recipe(_ logo: WatermarkLogo, size: Double, position: WatermarkPosition = .bottomLeft) -> Recipe {
        var recipe = Recipe()
        recipe.set(.watermark, .watermark(Watermark(logo: logo, position: position)), at: testClock.now())
        recipe.setScalar(.watermarkSize, size, at: testClock.now())
        recipe.setScalar(.watermarkOpacity, 100, at: testClock.now())
        recipe.setScalar(.watermarkMargin, 0, at: testClock.now())
        return recipe
    }

    /// The bounding box of bright pixels, in Core Image coordinates (origin at the
    /// bottom left; `pixels` lists rows from the top).
    static func brightBounds(_ image: CIImage, size: Int) -> CGRect? {
        let all = pixels(image, rect: CGRect(x: 0, y: 0, width: size, height: size))
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for (index, p) in all.enumerated() where p.x > 0.5 {
            let x = index % size, y = size - 1 - index / size
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: No defaults

    @Test func aNewWatermarkIsEmptyAndDrawsNothing() {
        #expect(Watermark().isEmpty)
        #expect(Watermark().text == "")
        var recipe = Recipe()
        recipe.set(.watermark, .watermark(Watermark()), at: testClock.now())
        #expect(Finishing.watermark(recipe) == nil)
        let base = solid(0, 0, 0, size: 100)
        #expect(pixels(FinishingRenderer.apply(recipe, to: base), rect: base.extent).allSatisfy { $0.x == 0 })
    }

    // MARK: Recipe value

    @Test func logoRoundTripsAndTextWatermarksEncodeAsBefore() throws {
        let logo = WatermarkLogo(hash: "abc", name: "Studio", format: "pdf")
        var recipe = Recipe()
        recipe.set(.watermark, .watermark(Watermark(logo: logo, position: .topRight)), at: testClock.now())
        let decoded = try RecipeCodec.decode(RecipeCodec.encode(recipe))
        #expect(Finishing.watermark(decoded)?.logo == logo)
        #expect(Finishing.watermark(decoded)?.position == .topRight)

        // A text watermark writes no logo key, so its stored form is unchanged.
        recipe.set(.watermark, .watermark(Watermark(text: "© Me")), at: testClock.now())
        #expect(!String(decoding: try RecipeCodec.encode(recipe), as: UTF8.self).contains("logo"))
    }

    // MARK: Store

    @Test func importsBitmapsAsPNGAndPDFsAsVectors() throws {
        let store = Self.store()
        let png = try store.logos!.importLogo(bitmap: Self.pngLogo(), name: "Mark")
        #expect(png.format == "png")
        #expect(store.aspectRatio(of: png) == 2)
        let pdfData = Self.pdfLogo()
        let pdf = try store.logos!.importLogo(pdf: pdfData, name: "Vector")
        #expect(pdf.format == "pdf")
        #expect(store.aspectRatio(of: pdf) == 3)

        // A PDF is drawn at the size asked for, opaque where the logo is.
        let image = try #require(store.image(for: pdf, size: CGSize(width: 600, height: 200)))
        #expect(image.width == 600 && image.height == 200)

        // The same file imported again is the same logo.
        #expect(try store.logos!.importLogo(pdf: pdfData, name: "Again").hash == pdf.hash)
        #expect(throws: WatermarkLogoStore.ImportError.self) { try store.logos!.importLogo(bitmap: Data("not an image".utf8), name: "x") }
        #expect(throws: WatermarkLogoStore.ImportError.self) { try store.logos!.importLogo(pdf: Data("%PDF-nonsense".utf8), name: "x") }
    }

    @Test func largeBitmapsAreScaledDownOnImport() throws {
        let store = Self.store()
        let logo = try store.logos!.importLogo(bitmap: Self.pngLogo(width: 6000, height: 1500), name: "Big")
        let data = try #require(store.logos!.data(for: logo))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == WatermarkLogoStore.maxBitmapEdge)
        #expect(store.aspectRatio(of: logo) == 4)
    }

    // MARK: Drawing

    @Test func logoFitsTheWatermarkHeightInItsCorner() throws {
        let store = Self.store()
        let logo = try store.logos!.importLogo(bitmap: Self.pngLogo(), name: "Mark")
        // 10% of a 400 px photo: 40 px tall, 80 px wide (2:1), bottom left.
        let image = FinishingRenderer.apply(Self.recipe(logo, size: 10), to: solid(0, 0, 0, size: 400), files: store)
        let bounds = try #require(Self.brightBounds(image, size: 400))
        #expect(abs(bounds.width - 80) <= 1 && abs(bounds.height - 40) <= 1, "\(bounds)")
        #expect(bounds.minX <= 1 && bounds.minY <= 1, "\(bounds)")
    }

    @Test func wideLogosShrinkToFitBetweenTheMargins() throws {
        let store = Self.store()
        // 10:1. On a 200 × 400 photo, 20% of the short edge is 40 px tall, which
        // would be 400 px wide: too wide.
        let logo = try store.logos!.importLogo(pdf: Self.pdfLogo(width: 1000), name: "Wide")
        var recipe = Self.recipe(logo, size: 20, position: .center)
        recipe.setScalar(.watermarkMargin, 5, at: testClock.now())
        let narrow = solid(0, 0, 0, size: 400).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 400))
        let image = FinishingRenderer.apply(recipe, to: narrow, files: store)
        let bounds = try #require(Self.brightBounds(image.cropped(to: CGRect(x: 0, y: 0, width: 200, height: 400)), size: 400))
        // Margin 5% of the short edge (200) = 10 px each side: 180 px wide, 18 tall.
        #expect(abs(bounds.width - 180) <= 1 && abs(bounds.height - 18) <= 1, "\(bounds)")
        #expect(abs(bounds.minX - 10) <= 1, "\(bounds)")
    }

    @Test func aLogoWhoseFileIsMissingIsSkipped() {
        let missing = WatermarkLogo(hash: "0000", name: "Gone", format: "png")
        let base = solid(0, 0, 0, size: 100)
        let image = FinishingRenderer.apply(Self.recipe(missing, size: 20), to: base, files: Self.store())
        #expect(pixels(image, rect: base.extent).allSatisfy { $0.x == 0 })
    }

    // MARK: Remote editing

    @Test func theLogoTravelsWithRendersOnAnotherDevice() throws {
        let ipad = Self.store()
        let logo = try ipad.logos!.importLogo(bitmap: Self.pngLogo(), name: "Mark")
        let recipe = Self.recipe(logo, size: 10)
        let files = recipe.lutFiles(from: ipad)
        #expect(files.count == 1)
        #expect(files.first?.logo == logo)

        // The phone doesn't have it, but draws it from the file that came along.
        let phone = MergedLUTs(base: Self.store(), extra: [:], logos: Dictionary(uniqueKeysWithValues: files.map { ($0.hash, $0.data) }))
        #expect(phone.aspectRatio(of: logo) == 2)
        let image = FinishingRenderer.apply(recipe, to: solid(0, 0, 0, size: 400), files: phone)
        #expect(Self.brightBounds(image, size: 400) != nil)
    }
}

/// SVG logos are converted to vector PDFs on import.
@Suite struct SVGToPDFTests {
    static let svg = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 200 100">
      <rect x="0" y="0" width="100" height="100" fill="#ffffff"/>
    </svg>
    """.utf8)

    @MainActor @Test func convertsToATransparentVectorPDFAtTheSVGsSize() async throws {
        let pdf = try await SVGToPDF.convert(Self.svg)
        #expect(pdf.starts(with: Data("%PDF".utf8)))
        #expect(!String(decoding: pdf, as: UTF8.self).contains("/Subtype /Image"), "paths, not a bitmap")

        let store = WatermarkLogoTests.store()
        let logo = try store.logos!.importLogo(pdf: pdf, name: "Logo")
        #expect(store.aspectRatio(of: logo) == 2)
        // Drawn 4× larger than the SVG: the left half white, the right half clear.
        let image = try #require(store.image(for: logo, size: CGSize(width: 800, height: 400)))
        let drawn = CIImage(cgImage: image)
        #expect(pixel(drawn, x: 200, y: 200).w > 0.99)
        #expect(pixel(drawn, x: 600, y: 200).w < 0.01)
    }

    @MainActor @Test func viewBoxOnlySVGsGetASize() async throws {
        let pdf = try await SVGToPDF.convert(Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 30 10"><rect width="30" height="10"/></svg>"#.utf8))
        let store = WatermarkLogoTests.store()
        let logo = try store.logos!.importLogo(pdf: pdf, name: "x")
        let aspect = try #require(store.aspectRatio(of: logo))
        #expect(abs(aspect - 3) < 0.01, "\(aspect)")
    }

    @MainActor @Test func rejectsFilesThatArentSVG() async {
        await #expect(throws: SVGToPDF.ConversionError.self) { try await SVGToPDF.convert(Data("hello".utf8)) }
    }
}
