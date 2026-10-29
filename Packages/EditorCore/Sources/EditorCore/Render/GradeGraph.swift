import CoreImage
import Metal

/// The one Metal-backed `CIContext` the app uses, plus shared color spaces.
public enum RenderContext {
    public static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    public static let shared: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            .name: "LightEditor",
        ]
        if let device { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    /// Full-size renders for saving and export. A second context at low GPU
    /// priority, so preview frames never wait behind a multi-second render.
    public static let background: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            .priorityRequestLow: true,
            .name: "LightEditor background",
        ]
        if let device { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    /// The color space of decoded intermediates: scene-linear, wide gamut, extended range.
    public static let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    public static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
}

/// Resolves a recipe's LUT reference to parsed cube data.
public protocol LUTProvider: Sendable {
    func lut(for ref: LUTRef) -> CubeLUT?
}

/// Everything besides the recipe that the grade needs.
public struct GradeInputs: Sendable {
    public var defaults: PhotoDefaults
    public var luts: (any LUTProvider)?
    /// Off while the crop tool is open, so the whole frame stays visible.
    public var applyGeometry: Bool
    public var showClipping: Bool
    /// Computed AI masks for this photo.
    public var aiMasks: (any AIMaskProvider)?
    /// The mask layer to tint red on screen, while editing it.
    public var maskOverlay: UUID?
    /// An HSL band to visualize: its colors stay, the rest turns gray.
    public var hslSelection: HueBand?
    /// AI-filled patches for Remove spots.
    public var inpaints: (any InpaintProvider)?
    /// A smaller copy of the base image (same framing) for the wide blurs behind
    /// clarity and dehaze. They only carry broad brightness, so blurring a small
    /// copy and enlarging it looks the same and is far cheaper than blurring
    /// hundreds of full-resolution pixels around everything on screen. Previews
    /// only; exports leave it nil.
    public nonisolated(unsafe) var presenceGuide: CIImage?

    public init(defaults: PhotoDefaults, luts: (any LUTProvider)? = nil, applyGeometry: Bool = true, showClipping: Bool = false,
                aiMasks: (any AIMaskProvider)? = nil, maskOverlay: UUID? = nil) {
        self.defaults = defaults
        self.luts = luts
        self.applyGeometry = applyGeometry
        self.showClipping = showClipping
        self.aiMasks = aiMasks
        self.maskOverlay = maskOverlay
    }
}

/// Builds the Core Image graph for a recipe on top of a decoded base image.
///
/// This is a pure function of (base, recipe, inputs). Building the graph is cheap
/// (no pixels are touched), so the preview rebuilds it on every slider change and
/// Core Image fuses the color kernels into as few GPU passes as it can. Every
/// operation is resolution-independent, so a preview and a full-size export of the
/// same recipe match.
public enum GradeGraph {
    public static func apply(_ recipe: Recipe, to base: CIImage, inputs: GradeInputs) -> CIImage {
        var image = base
        let retouches = recipe.retouches
        if !retouches.isEmpty {
            // Retouch only changes when spots do; cached, slider moves don't redo it.
            image = RetouchRenderer.apply(retouches, to: image, inpaints: inputs.inpaints).insertingIntermediate(cache: true)
        }
        image = whiteBalance(image, recipe, inputs.defaults)
        image = tone(image, recipe)
        var guide = inputs.presenceGuide
        if var small = guide, recipe.scalar(.clarity) != nil || recipe.scalar(.dehaze) != nil {
            // The guide goes through the same stages up to presence.
            if !retouches.isEmpty {
                small = RetouchRenderer.apply(retouches, to: small, inpaints: inputs.inpaints).insertingIntermediate(cache: true)
            }
            guide = tone(whiteBalance(small, recipe, inputs.defaults), recipe)
        }
        image = presence(image, recipe, guide: guide)
        image = toneCurve(image, recipe)
        image = color(image, recipe)
        image = hsl(image, recipe)
        if let band = inputs.hslSelection, let index = HueBand.allCases.firstIndex(of: band) {
            image = Kernels.compiled.hslSelection.apply(extent: image.extent, arguments: [image, Float(index)]) ?? image
        }
        image = colorGrade(image, recipe)
        let masks = recipe.masks
        if !masks.isEmpty { image = MaskRenderer.apply(masks, to: image, inputs: inputs) }
        image = lut(image, recipe, inputs.luts)
        if inputs.applyGeometry { image = geometry(image, recipe) }
        image = vignette(image, recipe)
        image = grain(image, recipe)
        if inputs.showClipping { image = Kernels.compiled.clipping.apply(extent: image.extent, arguments: [image]) ?? image }
        return image
    }

    // MARK: Stages

    static func whiteBalance(_ image: CIImage, _ recipe: Recipe, _ defaults: PhotoDefaults) -> CIImage {
        guard recipe.scalar(.temperature) != nil || recipe.scalar(.tint) != nil else { return image }
        let shotTemperature = defaults.value(for: .temperature)
        let shotTint = defaults.value(for: .tint)
        let temperature = recipe.scalar(.temperature, defaults: defaults)
        let tint = recipe.scalar(.tint, defaults: defaults)
        // CITemperatureAndTint maps the `neutral` white point to `targetNeutral`. To
        // render "as if lit by T", we map T onto the white point the decoder used.
        let filter = CIFilter(name: "CITemperatureAndTint")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: temperature, y: tint), forKey: "inputNeutral")
        filter.setValue(CIVector(x: shotTemperature, y: shotTint), forKey: "inputTargetNeutral")
        return filter.outputImage ?? image
    }

    static func tone(_ image: CIImage, _ recipe: Recipe) -> CIImage {
        let exposure = recipe.scalar(.exposure) ?? 0
        let light = CIVector(
            x: (recipe.scalar(.contrast) ?? 0) / 100,
            y: (recipe.scalar(.highlights) ?? 0) / 100,
            z: (recipe.scalar(.shadows) ?? 0) / 100,
            w: (recipe.scalar(.whites) ?? 0) / 100
        )
        let blacks = (recipe.scalar(.blacks) ?? 0) / 100
        guard exposure != 0 || light != CIVector(x: 0, y: 0, z: 0, w: 0) || blacks != 0 else { return image }
        let ends = CIVector(x: blacks, y: pow(2, exposure), z: 0, w: 0)
        return Kernels.compiled.tone.apply(extent: image.extent, arguments: [image, light, ends]) ?? image
    }

    static func toneCurve(_ image: CIImage, _ recipe: Recipe) -> CIImage {
        guard case .curve(let points)? = recipe[.toneCurve], !points.isIdentityCurve else { return image }
        let samples = ToneCurveSampler.sample(points, count: 256)
        var rgb = [Float]()
        rgb.reserveCapacity(samples.count * 3)
        for value in samples { rgb += [value, value, value] }
        let filter = CIFilter(name: "CIColorCurves")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(rgb.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "inputCurvesData")
        filter.setValue(CIVector(x: 0, y: 1), forKey: "inputCurvesDomain")
        filter.setValue(RenderContext.sRGB, forKey: "inputColorSpace")
        return filter.outputImage ?? image
    }

    static func color(_ image: CIImage, _ recipe: Recipe) -> CIImage {
        var image = image
        if let vibrance = recipe.scalar(.vibrance) {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": vibrance / 100])
        }
        if let saturation = recipe.scalar(.saturation) {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + saturation / 100,
                kCIInputBrightnessKey: 0,
                kCIInputContrastKey: 1,
            ])
        }
        return image
    }

    static func hsl(_ image: CIImage, _ recipe: Recipe) -> CIImage {
        var values: [HSLComponent: [Double]] = [:]
        var any = false
        for component in HSLComponent.allCases {
            values[component] = HueBand.allCases.map { band in
                let value = (recipe.scalar(.hsl(band, component)) ?? 0) / 100
                if value != 0 { any = true }
                return value
            }
        }
        guard any else { return image }
        func vectors(_ component: HSLComponent) -> [CIVector] {
            let v = values[component]!
            return [CIVector(x: v[0], y: v[1], z: v[2], w: v[3]), CIVector(x: v[4], y: v[5], z: v[6], w: v[7])]
        }
        let arguments: [Any] = [image] + vectors(.hue) + vectors(.saturation) + vectors(.luminance)
        return Kernels.compiled.hsl.apply(extent: image.extent, arguments: arguments) ?? image
    }

    static func colorGrade(_ image: CIImage, _ recipe: Recipe) -> CIImage {
        var any = false
        func wheel(_ range: ToneRange) -> CIVector {
            let (x, y) = recipe[.gradeWheel(range)]?.pointValue ?? (0, 0)
            let lum = (recipe.scalar(.gradeLuminance(range)) ?? 0) / 100
            if x != 0 || y != 0 || lum != 0 { any = true }
            let polar = ColorMath.wheelPolar(x: x, y: y)
            let direction = ColorMath.oklabDirection(hue: polar.hue)
            let strength = polar.strength * 0.09
            return CIVector(x: direction.a * strength, y: direction.b * strength, z: lum * 0.15)
        }
        let shadows = wheel(.shadows), midtones = wheel(.midtones), highlights = wheel(.highlights), global = wheel(.global)
        guard any else { return image }
        let blendBalance = CIVector(
            x: (recipe.scalar(.gradeBlending) ?? 50) / 100,
            y: (recipe.scalar(.gradeBalance) ?? 0) / 100
        )
        return Kernels.compiled.grade.apply(
            extent: image.extent,
            arguments: [image, shadows, midtones, highlights, global, blendBalance]
        ) ?? image
    }

    static func lut(_ image: CIImage, _ recipe: Recipe, _ provider: (any LUTProvider)?) -> CIImage {
        guard case .lut(let ref, let amount)? = recipe[.lut], amount > 0, let cube = provider?.lut(for: ref) else { return image }
        let filter = CIFilter(name: "CIColorCubeWithColorSpace")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(cube.dimension, forKey: "inputCubeDimension")
        filter.setValue(cube.data, forKey: "inputCubeData")
        filter.setValue(RenderContext.sRGB, forKey: "inputColorSpace")
        guard let graded = filter.outputImage else { return image }
        if amount >= 1 { return graded }
        return graded.applyingFilter("CIMix", parameters: ["inputBackgroundImage": image, "inputAmount": amount])
    }

    /// Perspective, straighten, then crop. The crop rect is normalized to the
    /// corrected, straightened frame, which is scaled up just enough that no empty
    /// corners show.
    static func geometry(_ image: CIImage, _ recipe: Recipe) -> CIImage {
        let corrected = perspective(
            image,
            vertical: (recipe.scalar(.perspectiveVertical) ?? 0) / 100,
            horizontal: (recipe.scalar(.perspectiveHorizontal) ?? 0) / 100
        )
        guard case .crop(let geometry)? = recipe[.crop] else { return corrected }
        return applyGeometry(geometry, to: corrected)
    }

    /// Keystone correction. Positive vertical widens the top (fixing verticals that
    /// converge upward, as when tilting a camera up at a building); positive
    /// horizontal makes the right edge taller. Corners only ever move outward, so the
    /// original frame stays fully covered and is cropped back to its own extent.
    public static func perspective(_ image: CIImage, vertical: Double, horizontal: Double) -> CIImage {
        guard abs(vertical) > 1e-6 || abs(horizontal) > 1e-6 else { return image }
        let e = image.extent
        let k = 0.3
        var topLeft = CGPoint(x: e.minX, y: e.maxY), topRight = CGPoint(x: e.maxX, y: e.maxY)
        var bottomLeft = CGPoint(x: e.minX, y: e.minY), bottomRight = CGPoint(x: e.maxX, y: e.minY)
        let dx = abs(vertical) * k * e.width / 2
        if vertical > 0 {
            topLeft.x -= dx; topRight.x += dx
        } else {
            bottomLeft.x -= dx; bottomRight.x += dx
        }
        let dy = abs(horizontal) * k * e.height / 2
        if horizontal > 0 {
            topRight.y += dy; bottomRight.y -= dy
        } else {
            topLeft.y += dy; bottomLeft.y -= dy
        }
        return image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: topLeft),
            "inputTopRight": CIVector(cgPoint: topRight),
            "inputBottomLeft": CIVector(cgPoint: bottomLeft),
            "inputBottomRight": CIVector(cgPoint: bottomRight),
        ]).cropped(to: e)
    }

    /// Clarity (midtone local contrast), texture (fine detail) and dehaze. Blur
    /// radii are fractions of the frame, so previews and full-size exports match.
    /// With a `guide` at least 1.5× smaller, clarity's and dehaze's blurs come
    /// from it (see `GradeInputs.presenceGuide`); texture's blur is too fine for that.
    static func presence(_ image: CIImage, _ recipe: Recipe, guide: CIImage? = nil) -> CIImage {
        var image = image
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge.isFinite, longEdge > 0 else { return image }
        var guide = guide.flatMap { max($0.extent.width, $0.extent.height) * 1.5 <= longEdge ? $0 : nil }
        func blur(_ input: CIImage, fraction: Double) -> CIImage {
            let e = input.extent
            return input.clampedToExtent().applyingGaussianBlur(sigma: max(e.width, e.height) * fraction).cropped(to: e)
        }
        /// The image blurred by `fraction` of its long edge, from the guide when there is one.
        func blurred(_ fraction: Double) -> CIImage {
            guard let guide else { return blur(image, fraction: fraction) }
            let g = guide.extent
            return blur(guide, fraction: fraction)
                .clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -g.minX, y: -g.minY)
                    .concatenating(CGAffineTransform(scaleX: extent.width / g.width, y: extent.height / g.height))
                    .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
                .cropped(to: extent)
        }
        func localContrast(_ input: CIImage, _ blurred: CIImage, amount: Double, protect: Double) -> CIImage {
            Kernels.compiled.localContrast.apply(
                extent: input.extent, arguments: [input, blurred, CIVector(x: amount, y: protect)]
            ) ?? input
        }
        if let texture = recipe.scalar(.texture) {
            image = localContrast(image, blur(image, fraction: 0.0012), amount: texture / 100, protect: 0.3)
        }
        if let clarity = recipe.scalar(.clarity) {
            image = localContrast(image, blurred(0.012), amount: clarity / 100, protect: 1)
            // Keep the guide in step for dehaze, which blurs the clarity result.
            if let small = guide { guide = localContrast(small, blur(small, fraction: 0.012), amount: clarity / 100, protect: 1) }
        }
        if let dehaze = recipe.scalar(.dehaze) {
            image = Kernels.compiled.dehaze.apply(extent: extent, arguments: [image, blurred(0.03), dehaze / 100]) ?? image
        }
        return image
    }

    /// Monochrome film grain. Grain size is relative to the output frame, so a
    /// preview and a full-size export look alike.
    static func grain(_ image: CIImage, _ recipe: Recipe) -> CIImage {
        guard let amount = recipe.scalar(.grainAmount), amount > 0 else { return image }
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        let size = (recipe.scalar(.grainSize) ?? 25) / 100
        let scale = max(longEdge * (0.0003 + 0.0012 * size), 0.5)
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let noise = random
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingGaussianBlur(sigma: scale * 0.4)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        return Kernels.compiled.grain.apply(extent: extent, arguments: [image, noise, amount / 100]) ?? image
    }

    public static func applyGeometry(_ geometry: CropGeometry, to image: CIImage) -> CIImage {
        let extent = image.extent
        var output = image
        if abs(geometry.angle) > 1e-6 {
            output = output.transformed(by: straightenTransform(angle: geometry.angle, extent: extent))
        }
        let rect = geometry.rect
        let cropRect = CGRect(
            x: extent.minX + rect.x * extent.width,
            y: extent.minY + (1 - rect.y - rect.height) * extent.height,
            width: rect.width * extent.width,
            height: rect.height * extent.height
        ).integral.intersection(extent)
        return output.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
    }

    /// Rotation about the center, scaled so the rotated image covers the original frame.
    public static func straightenTransform(angle: Double, extent: CGRect) -> CGAffineTransform {
        let radians = angle * .pi / 180
        let c = abs(cos(radians)), s = abs(sin(radians))
        let w = extent.width, h = extent.height
        let scale = max(c + (h / w) * s, (w / h) * s + c)
        return CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
            .concatenating(CGAffineTransform(rotationAngle: radians))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: extent.midX, y: extent.midY))
    }

    static func vignette(_ image: CIImage, _ recipe: Recipe) -> CIImage {
        guard let amount = recipe.scalar(.vignetteAmount) else { return image }
        let extent = image.extent
        let halfDiagonal = (extent.width * extent.width + extent.height * extent.height).squareRoot() / 2
        let geometry = CIVector(x: extent.midX, y: extent.midY, z: halfDiagonal, w: extent.width / extent.height)
        let params = CIVector(x: amount / 100, y: (recipe.scalar(.vignetteMidpoint) ?? 50) / 100)
        return Kernels.compiled.vignette.apply(extent: extent, arguments: [image, geometry, params]) ?? image
    }
}
