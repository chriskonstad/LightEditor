import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EditorCore

/// Golden-image tests for the grading pipeline.
///
/// Rendering is a pure function of (original, recipe), so each case grades a fixed
/// synthetic chart with one recipe and compares the result, averaged into a 12 × 8 grid
/// of blocks, with a stored golden in `Fixtures/Goldens/`. They catch any change to
/// what a recipe looks like: a kernel edit, a reordered stage, a changed default.
///
/// When a change is intended, re-record and review the diff of the JSON files:
///
///     EDITORCORE_RECORD=1 scripts/test-fast.sh --filter RenderGolden
///
/// On a mismatch the actual render and the expected/actual grids are written as PNGs
/// to `build/test-artifacts/render-goldens/` for a look.
@Suite struct RenderGoldenTests {
    static let chartSize = CGSize(width: 96, height: 64)
    static let grid = (columns: 12, rows: 8)

    /// The synthetic chart: hue across, brightness up (deep shadows to bright
    /// highlights, past 1.0 for EDR headroom), and a neutral ramp along the bottom.
    static let chart: CIImage = {
        let width = Int(chartSize.width), height = Int(chartSize.height)
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                // Core Image's origin is bottom-left; row 0 of the bitmap is the top.
                let v = 1 - Double(y) / Double(height - 1)
                let rgb: (Double, Double, Double)
                if y >= height - 8 {
                    let g = pow(Double(x) / Double(width - 1), 2.2)
                    rgb = (g, g, g)
                } else {
                    let hue = Double(x) / Double(width) * 6
                    let sector = Int(hue) % 6, f = hue - floor(hue)
                    let (r, g, b): (Double, Double, Double) = switch sector {
                    case 0: (1, f, 0)
                    case 1: (1 - f, 1, 0)
                    case 2: (0, 1, f)
                    case 3: (0, 1 - f, 1)
                    case 4: (f, 0, 1)
                    default: (1, 0, 1 - f)
                    }
                    // Desaturate toward the top a little so the chart has pastels too.
                    let brightness = 0.002 + 1.4 * pow(v, 2.4), mix = 0.25 * v
                    rgb = ((r * (1 - mix) + mix) * brightness, (g * (1 - mix) + mix) * brightness, (b * (1 - mix) + mix) * brightness)
                }
                pixels[i] = Float(rgb.0)
                pixels[i + 1] = Float(rgb.1)
                pixels[i + 2] = Float(rgb.2)
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16, size: chartSize, format: .RGBAf, colorSpace: linearSRGB)
    }()

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let defaults: PhotoDefaults
        let edit: @Sendable (inout Recipe) -> Void
        var testDescription: String { name }

        init(_ name: String, defaults: PhotoDefaults = .generic, _ edit: @escaping @Sendable (inout Recipe) -> Void) {
            self.name = name
            self.defaults = defaults
            self.edit = edit
        }
    }

    static let warmDefaults = PhotoDefaults(values: [.temperature: 5500, .tint: 0])
    static let stampClock = HybridLogicalClock(node: "golden")

    static let cases: [Case] = [
        Case("identity") { _ in },
        Case("exposure") { $0.setScalar(.exposure, 1.25, at: stampClock.now()) },
        Case("contrast") { $0.setScalar(.contrast, 60, at: stampClock.now()) },
        Case("highlights-shadows") {
            $0.setScalar(.highlights, -70, at: stampClock.now())
            $0.setScalar(.shadows, 70, at: stampClock.now())
        },
        Case("whites-blacks") {
            $0.setScalar(.whites, 50, at: stampClock.now())
            $0.setScalar(.blacks, -50, at: stampClock.now())
        },
        Case("white-balance", defaults: warmDefaults) {
            $0.setScalar(.temperature, 7500, at: stampClock.now())
            $0.setScalar(.tint, 25, at: stampClock.now())
        },
        Case("vibrance-saturation") {
            $0.setScalar(.vibrance, 50, at: stampClock.now())
            $0.setScalar(.saturation, -30, at: stampClock.now())
        },
        Case("hsl-mixer") {
            $0.setScalar(.hsl(.blue, .hue), -60, at: stampClock.now())
            $0.setScalar(.hsl(.orange, .saturation), 50, at: stampClock.now())
            $0.setScalar(.hsl(.green, .luminance), -50, at: stampClock.now())
        },
        Case("color-grade") {
            $0.set(.gradeWheel(.shadows), .point(x: -0.4, y: -0.3), at: stampClock.now())
            $0.set(.gradeWheel(.highlights), .point(x: 0.3, y: 0.4), at: stampClock.now())
            $0.set(.gradeWheel(.global), .point(x: 0.1, y: 0), at: stampClock.now())
            $0.setScalar(.gradeLuminance(.midtones), 20, at: stampClock.now())
            $0.setScalar(.gradeBalance, -30, at: stampClock.now())
        },
        Case("tone-curve") {
            $0.set(.toneCurve, .curve([CurvePoint(x: 0, y: 0.08), CurvePoint(x: 0.25, y: 0.2), CurvePoint(x: 0.75, y: 0.82), CurvePoint(x: 1, y: 0.95)]), at: stampClock.now())
        },
        Case("clarity-texture-dehaze") {
            $0.setScalar(.clarity, 60, at: stampClock.now())
            $0.setScalar(.texture, 40, at: stampClock.now())
            $0.setScalar(.dehaze, 50, at: stampClock.now())
        },
        Case("vignette-grain") {
            $0.setScalar(.vignetteAmount, -60, at: stampClock.now())
            $0.setScalar(.vignetteMidpoint, 30, at: stampClock.now())
            $0.setScalar(.grainAmount, 40, at: stampClock.now())
        },
        Case("lens-corrections") {
            $0.setScalar(.lensDistortion, 40, at: stampClock.now())
            $0.setScalar(.lensFringeRed, 30, at: stampClock.now())
            $0.setScalar(.lensVignette, 50, at: stampClock.now())
        },
        Case("crop-straighten-perspective") {
            $0.set(.crop, .crop(CropGeometry(rect: NormalizedRect(x: 0.1, y: 0.05, width: 0.75, height: 0.8), angle: 4, aspect: nil)), at: stampClock.now())
            $0.setScalar(.perspectiveVertical, 25, at: stampClock.now())
        },
        Case("radial-mask") {
            $0.setMask(MaskLayer(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Radial", order: 1,
                components: [MaskComponent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                                           shape: .radial(center: NormalizedPoint(x: 0.3, y: 0.4), radiusX: 0.25, radiusY: 0.3, angle: 20, feather: 0.5))],
                adjustments: [.exposure: 1, .saturation: -60, .localTemperature: 40]
            ), at: stampClock.now())
        },
        Case("luminance-and-linear-masks") {
            $0.setMask(MaskLayer(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Sky", order: 1,
                components: [
                    MaskComponent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                                  shape: .linear(start: NormalizedPoint(x: 0.5, y: 0), end: NormalizedPoint(x: 0.5, y: 0.6))),
                    MaskComponent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, operation: .subtract,
                                  shape: .luminance(low: 0.7, high: 1, feather: 0.2)),
                ],
                adjustments: [.exposure: -0.8, .contrast: 30]
            ), at: stampClock.now())
        },
        Case("clone-spot") {
            $0.setRetouch(RetouchSpot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, order: 1, kind: .clone,
                strokes: [BrushStroke(points: [NormalizedPoint(x: 0.5, y: 0.5)], radius: 0.1)],
                sourceOffset: NormalizedPoint(x: 0.25, y: 0)
            ), at: stampClock.now())
        },
        Case("everything", defaults: warmDefaults) {
            $0.setScalar(.exposure, 0.4, at: stampClock.now())
            $0.setScalar(.contrast, 20, at: stampClock.now())
            $0.setScalar(.shadows, 30, at: stampClock.now())
            $0.setScalar(.highlights, -40, at: stampClock.now())
            $0.setScalar(.temperature, 6000, at: stampClock.now())
            $0.setScalar(.vibrance, 20, at: stampClock.now())
            $0.setScalar(.hsl(.blue, .saturation), -30, at: stampClock.now())
            $0.set(.gradeWheel(.shadows), .point(x: -0.3, y: -0.2), at: stampClock.now())
            $0.set(.toneCurve, .curve([CurvePoint(x: 0, y: 0.05), CurvePoint(x: 0.5, y: 0.55), CurvePoint(x: 1, y: 1)]), at: stampClock.now())
            $0.setScalar(.clarity, 20, at: stampClock.now())
            $0.setScalar(.vignetteAmount, -20, at: stampClock.now())
        },
    ]

    /// Largest allowed difference in any block's channel, and the allowed mean
    /// difference, in linear light. Loose enough for GPU-to-GPU float differences,
    /// tight enough that any visible change fails.
    static let maxTolerance: Float = 0.01
    static let meanTolerance: Float = 0.002

    @Test(arguments: cases)
    func matchesGolden(_ testCase: Case) throws {
        var recipe = Recipe()
        testCase.edit(&recipe)
        let image = GradeGraph.apply(recipe, to: Self.chart, inputs: GradeInputs(defaults: testCase.defaults))
        try GoldenImage.check(image, name: testCase.name, folder: "Goldens", maxTolerance: Self.maxTolerance, meanTolerance: Self.meanTolerance)
    }

    /// A case whose recipe silently does nothing would record an identity golden and
    /// guard nothing, so each one has to visibly change the chart.
    @Test(arguments: cases.filter { $0.name != "identity" })
    func caseChangesTheChart(_ testCase: Case) {
        var recipe = Recipe()
        testCase.edit(&recipe)
        let edited = GoldenImage.blocks(GradeGraph.apply(recipe, to: Self.chart, inputs: GradeInputs(defaults: testCase.defaults)))
        let identity = GoldenImage.blocks(GradeGraph.apply(Recipe(), to: Self.chart, inputs: GradeInputs(defaults: testCase.defaults)))
        let change = edited.rgb.count == identity.rgb.count ? zip(edited.rgb, identity.rgb).map { abs($0 - $1) }.max() ?? 0 : .infinity
        #expect(change > Self.maxTolerance * 3, "\(testCase.name) barely changes the chart (\(change))")
    }

    /// The goldens cover the pipeline only if the chart itself is stable.
    @Test func chartIsDeterministic() {
        let a = pixels(Self.chart), b = pixels(Self.chart)
        #expect(a == b)
        #expect(Self.chart.extent.size == Self.chartSize)
    }
}

/// Real RAW decodes, compared with goldens at a looser tolerance. They catch decoder
/// changes (an OS update to RAW 9, a changed RAW-stage default) that would make
/// existing edits look different. Set EDITORCORE_RAW_FIXTURES (scripts/test.sh --raw).
@Suite(.serialized) struct RawGoldenTests {
    static var rawFiles: [URL] {
        DecodeTests.fixtureFiles.filter { ["arw", "raf", "dng"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test(.enabled(if: !rawFiles.isEmpty)) func decodesMatchGoldens() async throws {
        let decoder = RawDecoder(cache: DecodeCache(directory: nil))
        for url in Self.rawFiles {
            let source = PhotoSource(url: url)
            let info = try await decoder.info(for: source)
            let decoded = try await decoder.decode(source, rawStage: RawStageParams(), longEdge: 384)
            let image = GradeGraph.apply(Recipe(), to: decoded.image, inputs: GradeInputs(defaults: info.defaults))
            let name = (url.lastPathComponent as NSString).deletingPathExtension
            try GoldenImage.check(image, name: name, folder: "Goldens/RAW", maxTolerance: 0.03, meanTolerance: 0.006)
        }
    }
}

/// Block-averaged golden images stored as JSON, so diffs are reviewable as text.
enum GoldenImage {
    struct Stored: Codable, Equatable {
        var width: Int
        var height: Int
        var columns: Int
        var rows: Int
        /// Linear RGB per block, rows from the top, rounded to 1/10 000.
        var rgb: [Float]
    }

    static var testsFolder: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }
    static var repoRoot: URL {
        testsFolder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static var artifactsFolder: URL {
        if let path = ProcessInfo.processInfo.environment["EDITORCORE_ARTIFACTS"] { return URL(fileURLWithPath: path) }
        return repoRoot.appending(path: "build/test-artifacts/render-goldens")
    }

    static func blocks(_ image: CIImage, columns: Int = RenderGoldenTests.grid.columns, rows: Int = RenderGoldenTests.grid.rows) -> Stored {
        let extent = image.extent.integral
        let values = pixels(image, rect: extent)
        let width = Int(extent.width), height = Int(extent.height)
        var rgb = [Float]()
        for row in 0..<rows {
            for column in 0..<columns {
                // Bitmap rows from `render` run top to bottom.
                let y0 = row * height / rows, y1 = (row + 1) * height / rows
                let x0 = column * width / columns, x1 = (column + 1) * width / columns
                var sum = SIMD4<Float>.zero
                for y in y0..<y1 { for x in x0..<x1 { sum += values[y * width + x] } }
                let mean = sum / Float(max(1, (y1 - y0) * (x1 - x0)))
                rgb += [mean.x, mean.y, mean.z].map { ($0 * 10_000).rounded() / 10_000 }
            }
        }
        return Stored(width: width, height: height, columns: columns, rows: rows, rgb: rgb)
    }

    static func check(_ image: CIImage, name: String, folder: String, maxTolerance: Float, meanTolerance: Float) throws {
        let actual = blocks(image)
        let file = testsFolder.appending(path: "Fixtures/\(folder)/\(name).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if ProcessInfo.processInfo.environment["EDITORCORE_RECORD"] == "1" {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(actual).write(to: file)
            Issue.record("Recorded \(file.lastPathComponent). Unset EDITORCORE_RECORD and run again.")
            return
        }
        guard let data = try? Data(contentsOf: file) else {
            Issue.record("No golden for \(name) at \(file.path). Record it with EDITORCORE_RECORD=1.")
            return
        }
        let expected = try JSONDecoder().decode(Stored.self, from: data)
        guard expected.width == actual.width, expected.height == actual.height, expected.rgb.count == actual.rgb.count else {
            Issue.record("\(name): rendered \(actual.width)×\(actual.height), golden is \(expected.width)×\(expected.height)")
            return
        }
        let differences = zip(expected.rgb, actual.rgb).map { abs($0 - $1) }
        let worst = differences.max() ?? 0
        let mean = differences.reduce(0, +) / Float(max(1, differences.count))
        if worst > maxTolerance || mean > meanTolerance {
            let worstIndex = differences.firstIndex(of: worst) ?? 0
            let block = worstIndex / 3
            let written = writeArtifacts(image: image, expected: expected, actual: actual, name: name)
            Issue.record("""
                \(name) no longer matches its golden: max difference \(worst) (allowed \(maxTolerance)) at block \
                column \(block % actual.columns), row \(block / actual.columns), channel \("RGB".map(String.init)[worstIndex % 3]); \
                mean \(mean) (allowed \(meanTolerance)). Images: \(written). If the change is intended, re-record with \
                EDITORCORE_RECORD=1.
                """)
        }
    }

    /// Writes the full render and the expected/actual grids (scaled up) as sRGB PNGs.
    private static func writeArtifacts(image: CIImage, expected: Stored, actual: Stored, name: String) -> String {
        let folder = artifactsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        func write(_ image: CIImage, _ suffix: String) {
            let url = folder.appending(path: "\(name)-\(suffix).png")
            try? RenderContext.shared.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: sRGB)
        }
        func gridImage(_ stored: Stored) -> CIImage {
            var rgba = [Float]()
            for i in stride(from: 0, to: stored.rgb.count, by: 3) { rgba += [stored.rgb[i], stored.rgb[i + 1], stored.rgb[i + 2], 1] }
            let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
            let small = CIImage(bitmapData: data, bytesPerRow: stored.columns * 16, size: CGSize(width: stored.columns, height: stored.rows), format: .RGBAf, colorSpace: linearSRGB)
            return small.samplingNearest().transformed(by: CGAffineTransform(scaleX: 16, y: 16))
        }
        write(image, "actual")
        write(gridImage(expected), "expected-grid")
        write(gridImage(actual), "actual-grid")
        return folder.path + "/\(name)-*.png"
    }
}
