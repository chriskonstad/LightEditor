import CoreImage

/// Manual lens corrections, for lenses the RAW decoder has no profile for and
/// for fine-tuning the ones it has: distortion, lateral chromatic aberration
/// (color fringes that grow toward the corners) and lens vignetting.
///
/// Vignetting is a brightness falloff, applied in linear light before grading,
/// like the lens's own. Distortion and fringing move pixels, so they run with
/// the other geometry (before perspective and crop), on the original frame. Masks
/// and retouch spots stay defined on the uncorrected frame, as with perspective.
public enum LensCorrection {
    /// Barrel or pincushion strength at the corners for a Distortion of ±100.
    static let maxDistortion = 0.2
    /// How much a fringe slider of ±100 scales its color channel.
    static let maxFringeScale = 0.002
    /// Stops of brightening or darkening in the corners at Lens vignetting ±100.
    static let maxVignetteStops = 2.0

    /// The keys that move pixels, and so change the frame like perspective does.
    public static let geometryKeys: [ParamKey] = [.lensDistortion, .lensFringeRed, .lensFringeBlue]

    /// Lens vignetting: positive brightens the corners, negative darkens them.
    /// Midpoint moves the falloff toward the corners.
    static func vignette(_ image: CIImage, _ recipe: Recipe) -> CIImage {
        guard let amount = recipe.scalar(.lensVignette), amount != 0 else { return image }
        let midpoint = recipe.scalar(.lensVignetteMidpoint) ?? 50
        let e = image.extent
        guard e.width.isFinite, e.width > 0, e.height > 0 else { return image }
        let halfDiagonal = hypot(e.width, e.height) / 2
        // The falloff is r^power: 1 starts right at the center, 5 only in the corners.
        let power = 1 + 4 * midpoint / 100
        let stops = amount / 100 * maxVignetteStops
        return compiled.vignette.apply(extent: e, arguments: [
            image, CIVector(x: e.midX, y: e.midY, z: halfDiagonal), CIVector(x: stops, y: power),
        ]) ?? image
    }

    /// Distortion and fringing in one warp. Positive Distortion corrects barrel
    /// distortion (straight lines bowing outward), negative corrects pincushion.
    /// The result is scaled so the frame stays covered.
    public static func warp(_ image: CIImage, _ recipe: Recipe) -> CIImage {
        let distortion = recipe.scalar(.lensDistortion) ?? 0
        let red = recipe.scalar(.lensFringeRed) ?? 0
        let blue = recipe.scalar(.lensFringeBlue) ?? 0
        guard distortion != 0 || red != 0 || blue != 0 else { return image }
        let e = image.extent
        guard e.width.isFinite, e.width > 0, e.height > 0 else { return image }
        let halfDiagonal = hypot(e.width, e.height) / 2
        let w = Mapping(distortion: distortion, red: red, blue: blue)
        // The farthest any pixel samples from where it lands, for the region of interest.
        let reach = ceil(w.maxShift * halfDiagonal) + 2
        let geometry = CIVector(x: e.midX, y: e.midY, z: halfDiagonal)
        let bounds = CIVector(x: e.minX + 0.5, y: e.minY + 0.5, z: e.maxX - 0.5, w: e.maxY - 0.5)
        // Core Image (iOS and macOS 27) smears edge pixels outside the frame once
        // the result is scaled and offset, as the preview does, if the warp's
        // input is clamped or its crop matches the warp's own extent. So the
        // input isn't clamped (the kernel holds its samples inside the frame
        // instead), and the warp is a pixel larger than the crop that follows.
        let source = image.samplingLinear()
        func warped(_ channel: Double) -> CIImage? {
            compiled.warp.apply(
                extent: e.insetBy(dx: -1, dy: -1),
                roiCallback: { _, rect in rect.insetBy(dx: -reach, dy: -reach) },
                image: source,
                arguments: [geometry, CIVector(x: w.k, y: w.scale, z: channel), bounds]
            )
        }
        guard let green = warped(1) else { return image }
        guard red != 0 || blue != 0 else { return green.cropped(to: e) }
        let redImage = red != 0 ? warped(w.redScale) : green
        let blueImage = blue != 0 ? warped(w.blueScale) : green
        guard let redImage, let blueImage,
              let combined = compiled.channels.apply(extent: e.insetBy(dx: -1, dy: -1), arguments: [redImage, green, blueImage]) else { return image }
        return combined.cropped(to: e)
    }

    /// Where each output pixel samples from: radius r (relative to the half
    /// diagonal) samples at r · scale · (1 + k·r²), and red and blue scale that further.
    struct Mapping {
        var k: Double
        var scale: Double
        var redScale: Double
        var blueScale: Double

        init(distortion: Double, red: Double, blue: Double) {
            k = -distortion / 100 * LensCorrection.maxDistortion
            redScale = 1 + red / 100 * LensCorrection.maxFringeScale
            blueScale = 1 + blue / 100 * LensCorrection.maxFringeScale
            // Pincushion correction samples past the corners; shrink until it
            // doesn't. (An enlarged color channel can still reach a few pixels
            // past them; the kernel holds every sample inside the frame.)
            scale = 1 / (1 + max(k, 0))
        }

        /// The source radius output radius `r` samples, for a channel scale.
        func source(_ r: Double, channel: Double = 1) -> Double { r * scale * (1 + k * r * r) * channel }

        /// The largest distance between a pixel and where it samples, in half diagonals.
        var maxShift: Double {
            stride(from: 0.0, through: 1.0, by: 0.05).map { r in
                [1, redScale, blueScale].map { abs(source(r, channel: $0) - r) }.max() ?? 0
            }.max() ?? 0
        }
    }

    // MARK: Kernels

    struct Compiled: @unchecked Sendable {
        let warp: CIWarpKernel
        let channels: CIColorKernel
        let vignette: CIColorKernel
    }

    static let compiled: Compiled = {
        func kernel(_ name: String, _ body: String) -> CIKernel {
            do {
                guard let kernel = try CIKernel.kernels(withMetalString: Kernels.helpers + body).first(where: { $0.name == name }) else {
                    fatalError("Missing kernel \(name)")
                }
                return kernel
            } catch {
                fatalError("Kernel \(name) failed to compile: \(error)")
            }
        }
        guard let warp = kernel("lensWarpKernel", warpSource) as? CIWarpKernel,
              let channels = kernel("lensChannelsKernel", channelsSource) as? CIColorKernel,
              let vignette = kernel("lensVignetteKernel", vignetteSource) as? CIColorKernel
        else { fatalError("A lens kernel compiled to the wrong kind") }
        return Compiled(warp: warp, channels: channels, vignette: vignette)
    }()

    static let warpSource = #"""
    // geometry = (centerX, centerY, halfDiagonal), params = (k, scale, channel scale),
    // bounds = the frame's outermost pixel centers (minX, minY, maxX, maxY).
    // Returns where the output pixel samples from, never outside the frame.
    extern "C" [[stitchable]] float2 lensWarpKernel(float4 geometry, float4 params, float4 bounds, coreimage::destination dest) {
        float2 d = dest.coord() - geometry.xy;
        float r2 = dot(d, d) / (geometry.z * geometry.z);
        float2 p = geometry.xy + d * (params.y * (1.0 + params.x * r2) * params.z);
        return clamp(p, bounds.xy, bounds.zw);
    }
    """#

    static let channelsSource = #"""
    // Red from one warp, green and alpha from another, blue from a third.
    extern "C" [[stitchable]] float4 lensChannelsKernel(coreimage::sample_t r, coreimage::sample_t g, coreimage::sample_t b) {
        return float4(r.r, g.g, b.b, g.a);
    }
    """#

    static let vignetteSource = #"""
    // geometry = (centerX, centerY, halfDiagonal), params = (stops at the corners, falloff power).
    extern "C" [[stitchable]] float4 lensVignetteKernel(coreimage::sample_t s, float4 geometry, float2 params, coreimage::destination dest) {
        float r = min(length(dest.coord() - geometry.xy) / geometry.z, 1.0);
        float gain = exp2(params.x * pow(r, params.y));
        return float4(s.rgb * gain, s.a);
    }
    """#
}
