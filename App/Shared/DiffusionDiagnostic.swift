#if DEBUG
import CoreImage
import CoreML
import Darwin
import EditorCore
import Foundation
import ImageIO
import os
import Synchronization
import UniformTypeIdentifiers

/// Debug-only: `-DiagnoseDiffusion gpu|ane|cpu|all` runs one "LaMa + diffusion"
/// fill on a made-up 512 px image with the models on those compute units, and
/// logs `DIFF` lines: load and step timings, memory, and errors. No Photos
/// access. One compute unit per launch, since a failure can abort the process.
enum DiffusionDiagnostic {
    static func runIfRequested() {
        guard let mode = UserDefaults.standard.string(forKey: "DiagnoseDiffusion") else { return }
        Task.detached(priority: .userInitiated) { await run(mode: mode) }
    }

    static func log(_ text: String) {
        #if os(iOS)
        let available = "\(os_proc_available_memory() / 1_048_576) MB"
        #else
        let available = "n/a"
        #endif
        print("DIFF \(text) [now \(footprintMB) MB, peak \(peakFootprintMB) MB, available \(available)]")
    }

    static func run(mode: String) async {
        let units: MLComputeUnits = switch mode {
        case "ane": .cpuAndNeuralEngine
        case "cpu": .cpuOnly
        case "all": .all
        default: .cpuAndGPU
        }
        log("start \(mode), diffusion available \(DiffusionInpainter.shared.isAvailable)")
        DiffusionInpainter.shared.computeUnits = units
        do {
            let (image, mask) = try inputs()
            var clock = ContinuousClock.now
            let start = Inpainter.shared.isAvailable ? try Inpainter.shared.inpaint(image: image, mask: mask, size: DiffusionInpainter.size) : image
            log("LaMa in \(ContinuousClock.now - clock)")
            clock = .now
            let began = clock
            let steps = Mutex(0)
            let result = try await DiffusionInpainter.shared.inpaint(image: image, start: start, mask: mask, seed: 1) { _ in
                let step = steps.withLock { $0 += 1; return $0 }
                if step <= 2 || step % 6 == 0 { log("step \(step) at \(ContinuousClock.now - began)") }
            }
            log("diffusion done in \(ContinuousClock.now - clock)")
            write(result, name: "diffusion-\(mode).png")
            log("PASS \(mode) mean \(meanBrightness(result))")
        } catch {
            log("FAILED \(mode): \(error) — \(error.localizedDescription)")
        }
        DiffusionInpainter.shared.release()
        log("end")
    }

    /// Stripes and a gradient with a round hole in the middle.
    static func inputs() throws -> (CGImage, CGImage) {
        let rect = CGRect(x: 0, y: 0, width: 512, height: 512)
        let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor(red: 0.3, green: 0.5, blue: 0.7), "inputColor1": CIColor(red: 0.8, green: 0.7, blue: 0.5), "inputWidth": 24,
        ])!.outputImage!.cropped(to: rect)
        let maskImage = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 256, y: 256), "inputRadius0": 80, "inputRadius1": 82,
            "inputColor0": CIColor.white, "inputColor1": CIColor.black,
        ])!.outputImage!.cropped(to: rect)
        guard let image = RenderContext.background.createCGImage(stripes, from: rect, format: .RGBA8, colorSpace: RenderContext.sRGB),
              let mask = RenderContext.background.createCGImage(maskImage, from: rect, format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray))
        else { throw InpaintError.failed("couldn't make test images") }
        return (image, mask)
    }

    static func meanBrightness(_ image: CGImage) -> String {
        let average = CIImage(cgImage: image).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: 0, y: 0, width: image.width, height: image.height))])
        var pixel = [UInt8](repeating: 0, count: 4)
        RenderContext.background.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: RenderContext.sRGB)
        return "rgb \(pixel[0]) \(pixel[1]) \(pixel[2])"
    }

    static func write(_ image: CGImage, name: String) {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Diagnostics/out")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(folder.appending(path: name) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func taskInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    private static var footprintMB: Int { taskInfo().map { Int($0.phys_footprint / 1_048_576) } ?? -1 }
    private static var peakFootprintMB: Int { taskInfo().map { Int($0.ledger_phys_footprint_peak / 1_048_576) } ?? -1 }
}
#endif
