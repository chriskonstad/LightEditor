import Foundation
import Testing
@testable import EditorCore

/// Writes an identity (or transformed) .cube of the given size.
func makeCube(size: Int, title: String = "Test", transform: (Float, Float, Float) -> (Float, Float, Float) = { ($0, $1, $2) }) -> Data {
    var text = "# generated\r\nTITLE \"\(title)\"\r\nLUT_3D_SIZE \(size)\r\n"
    let n = Float(size - 1)
    for b in 0..<size {
        for g in 0..<size {
            for r in 0..<size {
                let (x, y, z) = transform(Float(r) / n, Float(g) / n, Float(b) / n)
                text += String(format: "%.6f %.6f %.6f\r\n", x, y, z)
            }
        }
    }
    return Data(text.utf8)
}

@Suite struct CubeParserTests {
    @Test(arguments: [2, 17, 33, 65])
    func parsesCommonSizes(size: Int) throws {
        let lut = try CubeParser.parse(makeCube(size: size))
        #expect(lut.dimension == size)
        #expect(lut.data.count == size * size * size * 4 * MemoryLayout<Float>.size)
        lut.data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            // Last entry is white, red varies fastest.
            #expect(floats[(size * size * size - 1) * 4] == 1)
            #expect(abs(floats[4] - 1 / Float(size - 1)) < 1e-5)
            #expect(floats[5] == 0)
            #expect(floats[7] == 1, "alpha is filled in")
        }
    }

    @Test func readsTitleAndHash() throws {
        let data = makeCube(size: 2, title: "Portra 400")
        let lut = try CubeParser.parse(data)
        #expect(lut.title == "Portra 400")
        #expect(lut.hash.count == 64)
        #expect(try CubeParser.parse(data).hash == lut.hash)
    }

    @Test func rescalesDomain() throws {
        let lut = try CubeParser.parse(try fixture("tiny_domain.cube"))
        #expect(lut.title == "Tiny Domain")
        lut.data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            // Domain 0...2 resampled to 0...1: the unit cube's far corner maps to input 1.0 (half the domain).
            #expect(abs(floats[7 * 4] - 0.5) < 1e-5)
        }
    }

    @Test func rejectsBadFiles() {
        #expect(throws: CubeParseError.missingSize) { try CubeParser.parse(Data("0 0 0\n".utf8)) }
        #expect(throws: CubeParseError.oneDimensional) { try CubeParser.parse(Data("LUT_1D_SIZE 4\n".utf8)) }
        #expect(throws: CubeParseError.wrongEntryCount(expected: 8, found: 1)) { try CubeParser.parse(Data("LUT_3D_SIZE 2\n0 0 0\n".utf8)) }
        #expect(throws: CubeParseError.unsupportedSize(1)) { try CubeParser.parse(Data("LUT_3D_SIZE 1\n".utf8)) }
    }

    @Test func storeImportsAndResolves() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = directory.appending(path: "Warm.cube")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try makeCube(size: 9, title: "Warm").write(to: file)
        let store = LUTStore(directory: directory.appending(path: "store"))
        let lut = try store.importCube(from: file)
        #expect(store.all() == [lut.ref])
        let fresh = LUTStore(directory: directory.appending(path: "store"))
        #expect(fresh.lut(for: lut.ref)?.dimension == 9)
    }
}

@Suite struct XMPImporterTests {
    @Test func mapsLightroomPreset() throws {
        let result = try XMPImporter.importPreset(from: try fixture("lightroom_preset.xmp"), fallbackName: "file")
        let params = result.preset.params
        #expect(result.preset.name == "Coastal Film")
        #expect(params[.exposure] == .scalar(0.35))
        #expect(params[.contrast] == .scalar(18))
        #expect(params[.highlights] == .scalar(-42))
        #expect(params[.temperature] == .scalar(5600))
        #expect(params[.tint] == .scalar(8))
        #expect(params[.vibrance] == .scalar(20))
        #expect(params[.hsl(.orange, .hue)] == .scalar(-6))
        #expect(params[.hsl(.blue, .saturation)] == .scalar(-25))
        #expect(params[.hsl(.green, .luminance)] == .scalar(10))
        #expect(params[.gradeBlending] == .scalar(60))
        #expect(params[.vignetteAmount] == .scalar(-15))
        #expect(params[.sharpness] == .scalar(40))

        guard let (x, y) = params[.gradeWheel(.shadows)]?.pointValue else { Issue.record("no shadow wheel"); return }
        let polar = ColorMath.wheelPolar(x: x, y: y)
        #expect(abs(polar.hue - 210) < 1e-6)
        #expect(abs(polar.strength - 0.2) < 1e-9)

        guard case .curve(let curve)? = params[.toneCurve] else { Issue.record("no curve"); return }
        #expect(curve.count == 3)
        #expect(abs(curve[0].y - 12.0 / 255) < 1e-9)

        #expect(params[.clarity] == .scalar(15))
        #expect(params[.dehaze] == .scalar(10))
        #expect(params[.texture] == nil, "zero values stay absent")
        #expect(result.unmapped.isEmpty, "unexpected: \(result.unmapped)")
        #expect(result.preset.groups.isSuperset(of: [.light, .whiteBalance, .color, .grade, .effects, .detail]))
    }

    @Test func asShotWhiteBalanceIsSkipped() throws {
        let xmp = #"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:WhiteBalance="As Shot" crs:Temperature="5000" crs:Exposure2012="+1.00"/></rdf:RDF></x:xmpmeta>"#
        let result = try XMPImporter.importPreset(from: Data(xmp.utf8), fallbackName: "Sidecar")
        #expect(result.preset.name == "Sidecar")
        #expect(result.preset.params[.temperature] == nil)
        #expect(result.preset.params[.exposure] == .scalar(1))
    }

    @Test func reportsUnmappedSettings() throws {
        let xmp = #"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="+0.50" crs:LensProfileEnable="0" crs:GrainFrequency="40" crs:Defringe="1"/></rdf:RDF></x:xmpmeta>"#
        let result = try XMPImporter.importPreset(from: Data(xmp.utf8), fallbackName: "x")
        #expect(result.unmapped == ["Defringe", "GrainFrequency"])
        #expect(result.preset.params[.lensCorrection] == .scalar(0))
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try XMPImporter.importPreset(from: Data("not xml".utf8), fallbackName: "x") }
    }
}
