import CoreGraphics
import CoreImage
import CryptoKit
import Foundation

/// Supplies AI-filled patches for Remove spots, computed ahead of time.
public protocol InpaintProvider: Sendable {
    /// The filled patch for the spot whose chain key is `key`, placed in `extent`.
    func patch(for key: String, in extent: CGRect) -> CIImage?
}

/// Applies retouch spots to the original image, before any grading.
///
/// Spots are in normalized coordinates of the original image, so they render the
/// same at preview and export sizes. Each spot works on the result of the ones
/// before it.
public enum RetouchRenderer {
    public static func apply(_ spots: [RetouchSpot], to image: CIImage, inpaints: (any InpaintProvider)?) -> CIImage {
        var output = image
        let extent = image.extent
        let keys = spots.contains { $0.kind == .remove } ? chainKeys(spots) : []
        for (index, spot) in spots.enumerated() where !spot.strokes.isEmpty {
            let mask = spotMask(spot, extent: extent)
            let filled: CIImage?
            switch spot.kind {
            case .clone:
                filled = shifted(output, by: spot.sourceOffset, extent: extent)
            case .heal:
                filled = heal(output, spot: spot, extent: extent)
            case .remove:
                filled = inpaints?.patch(for: keys[index], in: extent)
            }
            guard let filled else { continue }
            output = filled.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: mask,
            ]).cropped(to: extent)
        }
        return output
    }

    /// Identifies a Remove result: the spot plus every spot before it, since the
    /// fill depends on the image those produced.
    public static func chainKey(_ spots: ArraySlice<RetouchSpot>) -> String {
        chainKeys(Array(spots)).last!
    }

    /// The chain key of every prefix, in one pass: `keys[i]` is `chainKey(spots[...i])`.
    public static func chainKeys(_ spots: [RetouchSpot]) -> [String] {
        var hasher = SHA256()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys  // Stable bytes, so keys match across runs.
        func key(_ hasher: SHA256) -> String {
            hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
        }
        guard !spots.isEmpty else { return [key(hasher)] }
        return spots.map { spot in
            if let data = try? encoder.encode(spot) { hasher.update(data: data) }
            return key(hasher)
        }
    }

    /// The spot's painted area as a soft gray mask, scaled by its opacity.
    static func spotMask(_ spot: RetouchSpot, extent: CGRect) -> CIImage {
        // Remove fills inside a loop drawn around an object, too.
        let mask: CIImage
        if spot.kind == .remove, let raster = BrushRasterizer.image(spot.strokes, aspect: extent.width / extent.height, fillingEnclosed: true) {
            mask = MaskRenderer.fit(CIImage(cgImage: raster), to: extent)
        } else {
            mask = MaskRenderer.componentImage(.brush(strokes: spot.strokes), extent: extent, current: CIImage.empty(), ai: nil)
        }
        return spot.opacity >= 1 ? mask : MaskRenderer.scale(mask, by: spot.opacity)
    }

    /// The image moved so each target pixel shows its source pixel.
    static func shifted(_ image: CIImage, by offset: NormalizedPoint?, extent: CGRect) -> CIImage? {
        guard let offset else { return nil }
        // Source = target + offset, so move the image by −offset (y is flipped in Core Image).
        return image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -offset.x * extent.width, y: offset.y * extent.height))
            .cropped(to: extent)
    }

    static func heal(_ image: CIImage, spot: RetouchSpot, extent: CGRect) -> CIImage? {
        guard let source = shifted(image, by: spot.sourceOffset, extent: extent) else { return nil }
        let radius = (spot.strokes.map(\.radius).max() ?? 0.02) * max(extent.width, extent.height)
        let sigma = max(radius * 0.8, 2)
        func low(_ input: CIImage) -> CIImage {
            input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        }
        // Weights: 1 around the spot, 0 inside it (with a little margin).
        let hole = spotMask(RetouchSpot(order: 0, kind: .heal, strokes: spot.strokes.map {
            var grown = $0
            grown.radius *= 1.25
            grown.feather = 0
            return grown
        }), extent: extent)
        let weight = hole.applyingFilter("CIColorInvert")
        let weighted = image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weight])
        return Kernels.compiled.heal.apply(extent: extent, arguments: [source, low(source), low(weighted), low(weight)])
    }

    // MARK: Choosing a source

    /// Picks where heal and clone copy from, like content-aware healing: the nearby
    /// position whose surroundings best match the spot's surroundings, pixel by
    /// pixel. Matching the ring around the spot (not its contents, which are the
    /// blemish) makes the copied texture continue the structure around it.
    public static func autoSource(for spot: RetouchSpot, in image: CGImage) -> NormalizedPoint {
        let width = 256, height = max(Int(256 * Double(image.height) / Double(image.width)), 16)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let fallback = NormalizedPoint(x: spot.bounds.width * 1.4, y: 0)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: RenderContext.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return fallback }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let target = spot.bounds
        guard target.width > 0 else { return fallback }
        // In analysis pixels (row 0 is the top).
        let tx0 = Int(target.x * Double(width)), ty0 = Int(target.y * Double(height))
        let tw = max(Int((target.width * Double(width)).rounded(.up)), 2), th = max(Int((target.height * Double(height)).rounded(.up)), 2)
        let margin = max(max(tw, th) / 3, 2)

        // The ring: pixels within `margin` of the spot's box but outside it.
        var ring: [(dx: Int, dy: Int)] = []
        for dy in -margin..<(th + margin) {
            for dx in -margin..<(tw + margin) where dx < 0 || dy < 0 || dx >= tw || dy >= th {
                ring.append((dx, dy))
            }
        }
        // Sample a subset on big spots to keep this fast.
        let stride = max(ring.count / 600, 1)
        let samples = Swift.stride(from: 0, to: ring.count, by: stride).map { ring[$0] }

        func pixel(_ x: Int, _ y: Int) -> SIMD3<Float>? {
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let i = (y * width + x) * 4
            return SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / 255
        }

        func cost(_ ox: Int, _ oy: Int) -> Float? {
            // The source box must be fully inside the image.
            guard tx0 + ox >= 0, ty0 + oy >= 0, tx0 + ox + tw <= width, ty0 + oy + th <= height else { return nil }
            var total: Float = 0, count: Float = 0
            for (dx, dy) in samples {
                guard let a = pixel(tx0 + dx, ty0 + dy), let b = pixel(tx0 + ox + dx, ty0 + oy + dy) else { continue }
                let d = a - b
                total += (d * d).sum()
                count += 1
            }
            return count > 0 ? total / count : nil
        }

        var best: (ox: Int, oy: Int, cost: Float)?
        let size = Double(max(tw, th))
        for distance in [1.1, 1.4, 1.8, 2.4, 3.2, 4.2] {
            for step in 0..<24 {
                let angle = Double(step) * .pi / 12
                let ox = Int((cos(angle) * size * distance).rounded()), oy = Int((sin(angle) * size * distance).rounded())
                // Overlapping the spot would copy the blemish itself.
                guard abs(ox) >= tw || abs(oy) >= th, let c = cost(ox, oy) else { continue }
                let penalized = c * Float(1 + distance * 0.04)  // Prefer nearby sources on ties.
                if best == nil || penalized < best!.cost { best = (ox, oy, penalized) }
            }
        }
        guard let best else { return fallback }
        return NormalizedPoint(x: Double(best.ox) / Double(width), y: Double(best.oy) / Double(height))
    }

    /// The area the fill model sees for a spot: the spot plus context around it,
    /// square in pixels, at least `minimumSide` pixels so the model never
    /// upscales, and inside the frame (normalized).
    public static func inpaintRegion(for spot: RetouchSpot, imageSize: CGSize, minimumSide: CGFloat = 512) -> NormalizedRect {
        let bounds = spot.bounds
        let w = imageSize.width, h = imageSize.height
        let side = min(max(max(bounds.width * w, bounds.height * h) * 2.4, minimumSide), min(w, h))
        let centerX = (bounds.x + bounds.width / 2) * w, centerY = (bounds.y + bounds.height / 2) * h
        let x = min(max(centerX - side / 2, 0), w - side), y = min(max(centerY - side / 2, 0), h - side)
        return NormalizedRect(x: x / w, y: y / h, width: side / w, height: side / h)
    }
}
