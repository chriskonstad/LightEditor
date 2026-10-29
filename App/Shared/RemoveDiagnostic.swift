#if DEBUG
import CoreImage
import CoreML
import Darwin
import EditorCore
import Foundation
import Synchronization
import ImageIO
import UniformTypeIdentifiers

/// Debug-only: `-DiagnoseRemove YES` runs AI removal on the RAW files in
/// Documents/Diagnostics/in without any UI or Photos access, and writes timings,
/// errors, memory and result crops to Documents/Diagnostics/out. Used to debug
/// removal on a real device, where the simulator can't stand in (GPU, Neural Engine).
enum RemoveDiagnostic {
    static func runIfRequested() {
        if UserDefaults.standard.bool(forKey: "RenderBenchmark") {
            Task.detached(priority: .userInitiated) { await runBenchmark() }
            return
        }
        guard UserDefaults.standard.bool(forKey: "DiagnoseRemove") else { return }
        Task.detached(priority: .userInitiated) { await run() }
    }

    /// `-RenderBenchmark YES`: times the preview pipeline on the first RAW in
    /// Documents/Diagnostics/in, writing Documents/Diagnostics/out/bench.txt.
    static func runBenchmark() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Diagnostics")
        let output = documents.appending(path: "out")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: documents.appending(path: "in"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "arw" }
        guard let url = files.first else { print("BENCH no ARW"); return }
        let lines = Mutex<[String]>([])
        await RenderBenchmark.run(url: url) { line in
            print("BENCH \(line)")
            let all = lines.withLock { $0.append(line); return $0 }
            try? all.joined(separator: "\n").write(to: output.appending(path: "bench.txt"), atomically: true, encoding: .utf8)
        }
    }

    private static var footprintMB: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    static func run() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Diagnostics")
        let input = documents.appending(path: "in"), output = documents.appending(path: "out")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var lines: [String] = []
        func log(_ text: String) {
            let line = "DIAG \(text) [\(footprintMB) MB]"
            print(line)
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: output.appending(path: "log.txt"), atomically: true, encoding: .utf8)
        }
        let files = ((try? FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        log("start, \(files.count) files, model \(Inpainter.shared.isAvailable)")
        for url in files where !UserDefaults.standard.bool(forKey: "ProbeOnly") {
            let source = PhotoSource(url: url, key: "diag-\(url.lastPathComponent)")
            do {
                var clock = ContinuousClock.now
                let preview = try await RawDecoder.shared.decode(source, rawStage: RawStageParams(), longEdge: 2560).image
                log("\(url.lastPathComponent) preview \(preview.extent) in \(ContinuousClock.now - clock)")
                clock = .now
                let full = try await RawDecoder.shared.lazyImage(source, rawStage: RawStageParams(), longEdge: nil).0
                log("full extent \(full.extent) in \(ContinuousClock.now - clock)")
                // A round spot a bit right of center.
                let stroke = BrushStroke(points: [NormalizedPoint(x: 0.6, y: 0.5), NormalizedPoint(x: 0.64, y: 0.52)], radius: 0.04, feather: 0.35)
                let fullBox = UncheckedImage(full)
                for engine in [RemoveEngine.fast, .standard] {
                    let store = InpaintStore(photoKey: UUID().uuidString, directory: nil)
                    var recipe = Recipe()
                    recipe.setRetouch(RetouchSpot(order: 1, kind: .remove, strokes: [stroke], engine: engine), at: HLCStamp(millis: 1, node: "diag"))
                    clock = .now
                    do {
                        try await store.prepare(recipe, preview: preview, fullResolution: { fullBox.image })
                        log("\(engine) filled in \(ContinuousClock.now - clock), patch \(store.hasPatch(for: RetouchRenderer.chainKey(recipe.retouches[...0]))), model sizes full \(Inpainter.shared.fullSize)")
                    } catch {
                        log("\(engine) FAILED after \(ContinuousClock.now - clock): \(error)")
                        continue
                    }
                    var inputs = GradeInputs(defaults: .generic)
                    inputs.inpaints = store
                    for (name, base) in [("preview", preview), ("full", full)] {
                        let image = GradeGraph.apply(recipe, to: base, inputs: inputs)
                        let e = image.extent, b = recipe.retouches[0].bounds
                        let rect = CGRect(x: e.minX + (b.x - 0.05) * e.width, y: e.minY + (1 - b.y - b.height - 0.05) * e.height,
                                          width: (b.width + 0.1) * e.width, height: (b.height + 0.1) * e.height).integral
                        let before = RenderContext.background.createCGImage(base, from: rect, format: .RGBA8, colorSpace: RenderContext.sRGB)
                        let after = RenderContext.background.createCGImage(image, from: rect, format: .RGBA8, colorSpace: RenderContext.sRGB)
                        for (suffix, cg) in [("before", before), ("after", after)] {
                            guard let cg, let destination = CGImageDestinationCreateWithURL(
                                output.appending(path: "\(url.deletingPathExtension().lastPathComponent)-\(engine)-\(name)-\(suffix).png") as CFURL,
                                UTType.png.identifier as CFString, 1, nil) else { log("couldn't write \(suffix)"); continue }
                            CGImageDestinationAddImage(destination, cg, nil)
                            CGImageDestinationFinalize(destination)
                        }
                        log("\(engine) \(name) crops written")
                    }
                }
            } catch {
                log("\(url.lastPathComponent) FAILED: \(error)")
            }
        }
        await probeComputeUnits(files: files, output: output, log: log)
        log("done")
    }

    /// Runs LaMa's 1024 function on each compute unit, to see which gives a sane fill.
    private static func probeComputeUnits(files: [URL], output: URL, log: (String) -> Void) async {
        guard let modelURL = Bundle.main.url(forResource: "LaMa", withExtension: "mlmodelc"), let url = files.first,
              let full = try? await RawDecoder.shared.lazyImage(PhotoSource(url: url), rawStage: RawStageParams(), longEdge: nil).0 else { return }
        let size = 1024
        let crop = CGRect(x: full.extent.midX, y: full.extent.midY - 512, width: 1024, height: 1024)
        guard let image = RenderContext.background.createCGImage(full, from: crop, format: .RGBA8, colorSpace: RenderContext.sRGB) else { return }
        let maskImage = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 512, y: 512), "inputRadius0": 200, "inputRadius1": 202,
            "inputColor0": CIColor.white, "inputColor1": CIColor.black,
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        guard let mask = RenderContext.background.createCGImage(maskImage, from: maskImage.extent, format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray)) else { return }
        for (name, units) in [("all", MLComputeUnits.all), ("gpu", .cpuAndGPU), ("ane", .cpuAndNeuralEngine), ("cpu", .cpuOnly)] {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            configuration.functionName = "full"
            do {
                var clock = ContinuousClock.now
                let model = try MLModel(contentsOf: modelURL, configuration: configuration)
                let loaded = ContinuousClock.now - clock
                let input = try MLDictionaryFeatureProvider(dictionary: [
                    "image": try MLFeatureValue(cgImage: image, pixelsWide: size, pixelsHigh: size, pixelFormatType: kCVPixelFormatType_32BGRA, options: nil),
                    "mask": try MLFeatureValue(cgImage: mask, pixelsWide: size, pixelsHigh: size, pixelFormatType: kCVPixelFormatType_OneComponent8, options: nil),
                ])
                _ = try await model.prediction(from: input)
                clock = .now
                let result = try await model.prediction(from: input)
                let ran = ContinuousClock.now - clock
                if let buffer = result.featureValue(for: "output")?.imageBufferValue,
                   let cg = RenderContext.background.createCGImage(CIImage(cvPixelBuffer: buffer).settingAlphaOne(in: CGRect(x: 0, y: 0, width: size, height: size)), from: CGRect(x: 0, y: 0, width: size, height: size)),
                   let destination = CGImageDestinationCreateWithURL(output.appending(path: "units-\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, cg, nil)
                    CGImageDestinationFinalize(destination)
                }
                log("units \(name): load \(loaded), predict \(ran)")
            } catch {
                log("units \(name) FAILED: \(error.localizedDescription)")
            }
        }
    }
}
#endif
