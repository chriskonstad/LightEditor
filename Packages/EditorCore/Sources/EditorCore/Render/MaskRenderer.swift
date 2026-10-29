import CoreGraphics
import CoreImage
import Foundation
import Synchronization

/// Supplies AI masks (subject, sky, objects…) that were computed for this photo.
/// Lookups are synchronous and cheap; computing happens elsewhere, ahead of time.
public protocol AIMaskProvider: Sendable {
    /// The mask for an AI shape as an opaque gray image, or nil if it isn't ready.
    func mask(for shape: MaskShape) -> CIImage?
}

/// Turns mask layers into gray mask images and blends their local adjustments in.
///
/// Masks are defined on the original image (before crop and perspective), so they
/// apply before geometry in the grade graph. Every shape is resolution
/// independent: gradients and strokes are normalized, and AI masks are scaled to
/// whatever extent is being rendered.
public enum MaskRenderer {
    /// Applies every enabled layer, in order.
    public static func apply(_ layers: [MaskLayer], to image: CIImage, inputs: GradeInputs) -> CIImage {
        var output = image
        var overlay: CIImage?
        for layer in layers where layer.isEnabled {
            guard let mask = maskImage(layer, extent: image.extent, current: output, ai: inputs.aiMasks) else { continue }
            if layer.id == inputs.maskOverlay { overlay = mask }
            let hasAdjustments = layer.adjustments.values.contains { $0 != 0 }
            guard hasAdjustments, layer.amount > 0 else { continue }
            let adjusted = applyLocal(layer.adjustments, to: output)
            let weighted = layer.amount >= 1 ? mask : scale(mask, by: layer.amount)
            output = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: weighted,
            ]).cropped(to: image.extent)
        }
        if let overlay {
            output = Kernels.compiled.maskOverlay.apply(extent: output.extent, arguments: [output, overlay]) ?? output
        }
        return output
    }

    /// The combined mask of a layer, or nil when it has no components.
    public static func maskImage(_ layer: MaskLayer, extent: CGRect, current: CIImage, ai: (any AIMaskProvider)?) -> CIImage? {
        var result: CIImage?
        for component in layer.components {
            var mask = componentImage(component.shape, extent: extent, current: current, ai: ai)
            if component.inverted { mask = mask.applyingFilter("CIColorInvert") }
            switch component.operation {
            case .add:
                result = result.map { mask.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? mask
            case .subtract:
                let base = result ?? black(extent)
                result = mask.applyingFilter("CIColorInvert").applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: base])
            case .intersect:
                let base = result ?? black(extent)
                result = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: base])
            }
        }
        return result?.cropped(to: extent)
    }

    static func componentImage(_ shape: MaskShape, extent: CGRect, current: CIImage, ai: (any AIMaskProvider)?) -> CIImage {
        func point(_ p: NormalizedPoint) -> CGPoint {
            CGPoint(x: extent.minX + p.x * extent.width, y: extent.minY + (1 - p.y) * extent.height)
        }
        switch shape {
        case .linear(let start, let end):
            return CIFilter(name: "CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(cgPoint: point(start)),
                "inputPoint1": CIVector(cgPoint: point(end)),
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.black,
            ])!.outputImage!.cropped(to: extent)

        case .radial(let center, let radiusX, let radiusY, let angle, let feather):
            let unit = 1000.0
            let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0),
                "inputRadius0": unit * max(1 - feather, 0.001),
                "inputRadius1": unit,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.black,
            ])!.outputImage!
            let c = point(center)
            let transform = CGAffineTransform(scaleX: max(radiusX * extent.width, 1) / unit, y: max(radiusY * extent.height, 1) / unit)
                .concatenating(CGAffineTransform(rotationAngle: -angle * .pi / 180))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
            return gradient.transformed(by: transform).cropped(to: extent)

        case .brush(let strokes):
            guard let raster = BrushRasterizer.image(strokes, aspect: extent.width / extent.height) else { return black(extent) }
            return fit(CIImage(cgImage: raster), to: extent)

        case .luminance(let low, let high, let feather):
            return Kernels.compiled.luminanceMask.apply(extent: extent, arguments: [current, CIVector(x: low, y: high, z: feather)]) ?? black(extent)

        case .color(let l, let a, let b, let range):
            return Kernels.compiled.colorMask.apply(extent: extent, arguments: [current, CIVector(x: l, y: a, z: b, w: range)]) ?? black(extent)

        case .ai(kind: .background):
            // The inverse of the subject; with no subject yet, there's no background either.
            guard let subject = ai?.mask(for: .ai(kind: .subject)) else { return black(extent) }
            return fit(subject, to: extent).applyingFilter("CIColorInvert")
        case .ai, .object:
            guard let mask = ai?.mask(for: shape) else { return black(extent) }
            return fit(mask, to: extent)
        }
    }

    /// The local look: the same tone, presence and color stages as the global grade.
    static func applyLocal(_ adjustments: [ParamKey: Double], to image: CIImage) -> CIImage {
        var recipe = Recipe()
        let stamp = HLCStamp(millis: 0, node: "mask")
        let neutral = 6500.0
        for (key, value) in adjustments where value != 0 {
            switch key {
            case .localTemperature: recipe.setScalar(.temperature, neutral + value * 30, at: stamp)
            case .localTint: recipe.setScalar(.tint, value, at: stamp)
            default: recipe.setScalar(key, value, at: stamp)
            }
        }
        var output = GradeGraph.whiteBalance(image, recipe, PhotoDefaults(values: [.temperature: neutral, .tint: 0]))
        output = GradeGraph.tone(output, recipe)
        output = GradeGraph.presence(output, recipe)
        output = GradeGraph.color(output, recipe)
        return output
    }

    static func black(_ extent: CGRect) -> CIImage {
        CIImage(color: .black).cropped(to: extent)
    }

    static func scale(_ mask: CIImage, by amount: Double) -> CIImage {
        mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0),
        ])
    }

    /// Stretches a mask image over `extent`, smoothly.
    static func fit(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let source = mask.extent
        guard source.width > 0, source.height > 0 else { return black(extent) }
        let transform = CGAffineTransform(translationX: -source.minX, y: -source.minY)
            .concatenating(CGAffineTransform(scaleX: extent.width / source.width, y: extent.height / source.height))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return mask.clampedToExtent().transformed(by: transform).cropped(to: extent)
    }
}

/// Rasterizes brush strokes into a gray mask with Core Graphics, cached by content.
enum BrushRasterizer {
    static let longEdge = 1024
    /// Room for every brush mask and retouch spot of a busy photo (8-bit gray, under 1 MB each),
    /// so building the graph for a slider move never rasterizes on the main thread.
    static let cacheLimit = 96
    private static let cache = Mutex<(images: [Int: UncheckedBox<CGImage>], order: [Int])>(([:], []))

    /// `fillingEnclosed` paints areas the strokes fully enclose, so circling an
    /// object selects all of it (as Photoshop's Remove tool does).
    static func image(_ strokes: [BrushStroke], aspect: Double, fillingEnclosed: Bool = false) -> CGImage? {
        var hasher = Hasher()
        hasher.combine(strokes)
        hasher.combine(Int(aspect * 1000))
        hasher.combine(fillingEnclosed)
        let key = hasher.finalize()
        if let hit = cache.withLock({ $0.images[key] }) { return hit.value }

        let width = aspect >= 1 ? longEdge : max(Int(Double(longEdge) * aspect), 1)
        let height = aspect >= 1 ? max(Int(Double(longEdge) / aspect), 1) : longEdge
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let edge = Double(max(width, height))
        for stroke in strokes where !stroke.points.isEmpty {
            let level = stroke.erase ? 0.0 : 1.0
            let color = CGColor(gray: level, alpha: stroke.flow)
            let radius = stroke.radius * edge
            // A solid core plus a blurred shadow gives the feathered edge.
            let core = max(radius * (1 - stroke.feather * 0.6), 0.5)
            context.saveGState()
            context.setShadow(offset: .zero, blur: radius * stroke.feather * 1.2, color: color)
            context.setStrokeColor(color)
            context.setFillColor(color)
            context.setLineWidth(core * 2)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let points = stroke.points.map { CGPoint(x: $0.x * Double(width), y: (1 - $0.y) * Double(height)) }
            if points.count == 1 {
                context.fillEllipse(in: CGRect(x: points[0].x - core, y: points[0].y - core, width: core * 2, height: core * 2))
            } else {
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                context.addLines(between: points)
                context.strokePath()
                context.endTransparencyLayer()
            }
            context.restoreGState()
        }
        if fillingEnclosed { fillEnclosed(context, width: width, height: height) }
        guard let image = context.makeImage() else { return nil }
        cache.withLock { cache in
            // Evict the oldest entries first.
            if cache.images[key] == nil { cache.order.append(key) }
            cache.images[key] = UncheckedBox(image)
            while cache.order.count > cacheLimit { cache.images[cache.order.removeFirst()] = nil }
        }
        return image
    }

    /// Paints every unpainted pixel the outside can't reach: a flood fill from
    /// the border through pixels below half strength.
    private static func fillEnclosed(_ context: CGContext, width: Int, height: Int) {
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return }
        let row = context.bytesPerRow
        var outside = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        func visit(_ x: Int, _ y: Int) {
            let i = y * width + x
            guard !outside[i], data[y * row + x] < 128 else { return }
            outside[i] = true
            stack.append(i)
        }
        for x in 0..<width { visit(x, 0); visit(x, height - 1) }
        for y in 0..<height { visit(0, y); visit(width - 1, y) }
        while let i = stack.popLast() {
            let x = i % width, y = i / width
            if x > 0 { visit(x - 1, y) }
            if x < width - 1 { visit(x + 1, y) }
            if y > 0 { visit(x, y - 1) }
            if y < height - 1 { visit(x, y + 1) }
        }
        for y in 0..<height {
            for x in 0..<width where !outside[y * width + x] { data[y * row + x] = 255 }
        }
    }
}
