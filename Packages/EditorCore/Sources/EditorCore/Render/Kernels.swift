import CoreImage
import os

/// Custom Core Image kernels, for the stages no built-in filter covers.
///
/// The kernels are Metal source compiled once at first use with
/// `CIKernel.kernels(withMetalString:)`. That keeps them inside this Swift package,
/// so `swift test` exercises the exact code the app ships, without a separate
/// metallib build step. All kernels take and return linear, extended-range RGB in
/// Core Image's working space (linear sRGB primaries).
public enum Kernels {
    struct Compiled: @unchecked Sendable {
        let tone: CIColorKernel
        let hsl: CIColorKernel
        let grade: CIColorKernel
        let vignette: CIColorKernel
        let clipping: CIColorKernel
        let localContrast: CIColorKernel
        let dehaze: CIColorKernel
        let grain: CIColorKernel
        let luminanceMask: CIColorKernel
        let colorMask: CIColorKernel
        let maskOverlay: CIColorKernel
        let hslSelection: CIColorKernel
        let heal: CIColorKernel
    }

    static let compiled: Compiled = {
        let signpostID = Signposts.render.makeSignpostID()
        let state = Signposts.render.beginInterval("CompileKernels", id: signpostID)
        defer { Signposts.render.endInterval("CompileKernels", state) }
        return Compiled(
            tone: compile("toneKernel", toneSource),
            hsl: compile("hslKernel", hslSource),
            grade: compile("gradeKernel", gradeSource),
            vignette: compile("vignetteKernel", vignetteSource),
            clipping: compile("clippingKernel", clippingSource),
            localContrast: compile("localContrastKernel", localContrastSource),
            dehaze: compile("dehazeKernel", dehazeSource),
            grain: compile("grainKernel", grainSource),
            luminanceMask: compile("luminanceMaskKernel", luminanceMaskSource),
            colorMask: compile("colorMaskKernel", colorMaskSource),
            maskOverlay: compile("maskOverlayKernel", maskOverlaySource),
            hslSelection: compile("hslSelectionKernel", hslSelectionSource),
            heal: compile("healKernel", healSource)
        )
    }()

    /// Each kernel is compiled from its own source string. Core Image mixes up the
    /// render pipelines of kernels that come from one shared Metal source when they
    /// render in the same context (seen on macOS and iOS 27), so never batch them.
    private static func compile(_ name: String, _ body: String) -> CIColorKernel {
        do {
            let kernels = try CIKernel.kernels(withMetalString: helpers + body)
            guard let kernel = kernels.first(where: { $0.name == name }) as? CIColorKernel else {
                fatalError("Missing kernel \(name)")
            }
            return kernel
        } catch {
            fatalError("Kernel \(name) failed to compile: \(error)")
        }
    }

    /// Compiles the kernels ahead of first use, off the main thread.
    public static func warmUp() { _ = compiled }

    static let helpers = #"""
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    // ---- Shared color helpers -------------------------------------------------

    constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);

    // Oklab from linear sRGB (Björn Ottosson, public domain).
    float3 linearToOklab(float3 c) {
        float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
        float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
        float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
        l = sign(l) * pow(abs(l), 1.0 / 3.0);
        m = sign(m) * pow(abs(m), 1.0 / 3.0);
        s = sign(s) * pow(abs(s), 1.0 / 3.0);
        return float3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s);
    }

    float3 oklabToLinear(float3 lab) {
        float l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
        float m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
        float s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
        l = l * l * l; m = m * m * m; s = s * s * s;
        return float3(
             4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
    }

    float bump(float lo, float peak, float hi, float x) {
        return smoothstep(lo, peak, x) * (1.0 - smoothstep(peak, hi, x));
    }
    """#

    static let toneSource = #"""
    // ---- Tone -----------------------------------------------------------------
    // Exposure, then contrast / highlights / shadows / whites / blacks as a global
    // tone operator on luminance in a perceptual (gamma 2.2) domain. RGB is scaled
    // by the luminance ratio so hue is preserved.
    // light = (contrast, highlights, shadows, whites), ends = (blacks, exposureGain, 0, 0); all amounts in -1...1.

    float toneMap(float v, float4 light, float blacks) {
        float x = clamp(v, 0.0, 1.0);
        const float pivot = 0.46;
        float out = v;
        out += light.x * 0.9 * (x - pivot) * x * (1.0 - x) * 2.0;
        out += blacks * 0.12 * (1.0 - smoothstep(0.0, 0.3, x));
        out += light.z * 0.22 * bump(0.0, 0.25, 0.65, x);
        out += light.y * 0.22 * bump(0.35, 0.75, 1.05, x);
        out += light.w * 0.15 * smoothstep(0.55, 1.0, x);
        return out;
    }

    extern "C" [[stitchable]] float4 toneKernel(coreimage::sample_t s, float4 light, float4 ends) {
        float3 rgb = s.rgb * ends.y;
        float y = max(dot(rgb, kLuma), 0.0);
        if (y < 1e-6) { return float4(rgb, s.a); }
        float v = pow(y, 1.0 / 2.2);
        float v2 = max(toneMap(v, light, ends.x), 0.0);
        float y2 = pow(v2, 2.2);
        return float4(rgb * (y2 / y), s.a);
    }
    """#

    static let hslSource = #"""
    // ---- HSL mixer ------------------------------------------------------------
    // Eight hue bands in OkLCh. Each pixel's hue gives partition-of-unity weights
    // over its two neighboring bands, so adjustments blend smoothly with no banding.
    // Neutral pixels are left alone because every effect scales with chroma.

    constant float kBandHue[9] = { 0.51, 0.96, 1.92, 2.49, 3.40, 4.61, 5.06, 5.73, 6.79 };  // radians, wraps

    float bandParam(int i, float4 lo, float4 hi) {
        int j = i % 8;
        return j < 4 ? lo[j] : hi[j - 4];
    }

    extern "C" [[stitchable]] float4 hslKernel(coreimage::sample_t s, float4 hueLo, float4 hueHi, float4 satLo, float4 satHi, float4 lumLo, float4 lumHi) {
        float3 lab = linearToOklab(s.rgb);
        float chroma = length(lab.yz);
        if (chroma < 1e-5) { return s; }
        float h = atan2(lab.z, lab.y);
        if (h < kBandHue[0]) { h += 6.2831853; }

        int i = 0;
        for (int k = 0; k < 8; k++) { if (h >= kBandHue[k]) { i = k; } }
        float t = smoothstep(0.0, 1.0, (h - kBandHue[i]) / (kBandHue[i + 1] - kBandHue[i]));
        float hueShift = mix(bandParam(i, hueLo, hueHi), bandParam(i + 1, hueLo, hueHi), t);
        float satShift = mix(bandParam(i, satLo, satHi), bandParam(i + 1, satLo, satHi), t);
        float lumShift = mix(bandParam(i, lumLo, lumHi), bandParam(i + 1, lumLo, lumHi), t);

        float chromaWeight = smoothstep(0.0, 0.06, chroma);
        float newHue = h + hueShift * 0.5 * chromaWeight;
        float newChroma = chroma * max(1.0 + satShift * chromaWeight, 0.0);
        float newL = lab.x * (1.0 + lumShift * 0.35 * chromaWeight);
        float3 outLab = float3(newL, newChroma * cos(newHue), newChroma * sin(newHue));
        return float4(oklabToLinear(outLab), s.a);
    }
    """#

    static let gradeSource = #"""
    // ---- Color grading wheels -------------------------------------------------
    // Split toning in Oklab. Each wheel adds an (a, b) offset and a lightness shift,
    // weighted by the pixel's lightness; the global wheel applies everywhere.
    // balance moves the split points; blending widens the overlap.

    extern "C" [[stitchable]] float4 gradeKernel(coreimage::sample_t s, float3 shadows, float3 midtones, float3 highlights, float3 global, float2 blendBalance) {
        float3 lab = linearToOklab(s.rgb);
        float L = clamp(lab.x, 0.0, 1.0);
        float width = 0.06 + 0.3 * blendBalance.x;
        float shift = -0.18 * blendBalance.y;
        float sPivot = 0.35 + shift;
        float hPivot = 0.72 + shift;
        float ws = 1.0 - smoothstep(sPivot - width, sPivot + width, L);
        float wh = smoothstep(hPivot - width, hPivot + width, L);
        float wm = clamp(1.0 - ws - wh, 0.0, 1.0);
        float3 offset = ws * shadows + wm * midtones + wh * highlights + global;
        lab.yz += offset.xy;
        lab.x += offset.z * (0.25 + 0.75 * L);
        return float4(oklabToLinear(lab), s.a);
    }
    """#

    static let vignetteSource = #"""
    // ---- Vignette -------------------------------------------------------------
    // geometry = (centerX, centerY, halfDiagonal, aspect), params = (amount, midpoint).

    extern "C" [[stitchable]] float4 vignetteKernel(coreimage::sample_t s, float4 geometry, float2 params, coreimage::destination dest) {
        float2 d = dest.coord() - geometry.xy;
        float r = length(d) / geometry.z;
        float inner = 0.15 + 0.6 * params.y;
        float w = smoothstep(inner, 1.05, r);
        float amount = params.x;
        float3 rgb = s.rgb;
        if (amount < 0.0) {
            rgb *= 1.0 + amount * w * 0.9;
        } else {
            rgb = rgb + amount * w * 0.6 * (1.0 - clamp(rgb, 0.0, 1.0));
        }
        return float4(rgb, s.a);
    }
    """#

    static let clippingSource = #"""
    // ---- Clipping overlay -----------------------------------------------------

    extern "C" [[stitchable]] float4 clippingKernel(coreimage::sample_t s) {
        float3 c = s.rgb;
        if (max(c.r, max(c.g, c.b)) >= 0.999) { return float4(1.0, 0.1, 0.1, s.a); }
        if (dot(max(c, 0.0), kLuma) <= 0.0015) { return float4(0.1, 0.35, 1.0, s.a); }
        return s;
    }
    """#

    // ---- Local contrast (clarity and texture) ---------------------------------
    // Boosts the difference between luminance and a blurred copy, in a perceptual
    // domain. params = (amount -1...1, midtone protection 0...1). Midtone
    // protection keeps clarity from crushing shadows or blowing highlights.
    static let localContrastSource = #"""
    extern "C" [[stitchable]] float4 localContrastKernel(coreimage::sample_t s, coreimage::sample_t blurred, float2 params) {
        float y = max(dot(s.rgb, kLuma), 0.0);
        if (y < 1e-6) { return s; }
        float v = pow(y, 1.0 / 2.2);
        float vb = pow(max(dot(blurred.rgb, kLuma), 0.0), 1.0 / 2.2);
        float x = clamp(v, 0.0, 1.0);
        float weight = mix(1.0, 4.0 * x * (1.0 - x), params.y);
        float v2 = max(v + params.x * (v - vb) * weight * 1.5, 0.0);
        return float4(s.rgb * (pow(v2, 2.2) / y), s.a);
    }
    """#

    // ---- Dehaze ---------------------------------------------------------------
    // A dark-channel-style haze estimate from a heavily blurred copy: hazy regions
    // have a bright minimum channel. Positive amounts subtract the airlight and
    // re-expand contrast there; negative amounts add haze.
    static let dehazeSource = #"""
    extern "C" [[stitchable]] float4 dehazeKernel(coreimage::sample_t s, coreimage::sample_t blurred, float amount) {
        const float3 airlight = float3(0.9);
        float haze = clamp(min(blurred.r, min(blurred.g, blurred.b)) / 0.9, 0.0, 1.0);
        if (amount >= 0.0) {
            float t = max(1.0 - amount * 0.85 * haze, 0.25);
            float3 rgb = (s.rgb - airlight) / t + airlight;
            return float4(mix(s.rgb, rgb, 0.9), s.a);
        }
        float k = -amount * 0.55;
        return float4(mix(s.rgb, airlight * (0.6 + 0.4 * haze), k), s.a);
    }
    """#

    // ---- Film grain -----------------------------------------------------------
    // noise is a monochrome noise field around 0.5. Grain is strongest in the
    // midtones, like film. amount 0...1.
    static let grainSource = #"""
    extern "C" [[stitchable]] float4 grainKernel(coreimage::sample_t s, coreimage::sample_t noise, float amount) {
        float y = max(dot(s.rgb, kLuma), 0.0);
        float v = clamp(pow(y, 1.0 / 2.2), 0.0, 1.0);
        float weight = 0.35 + 2.6 * v * (1.0 - v);
        float n = (noise.g - 0.5) * amount * 0.45 * weight;
        float v2 = max(pow(y, 1.0 / 2.2) + n, 0.0);
        if (y < 1e-6) { return float4(float3(max(n, 0.0) * 0.1), s.a); }
        return float4(s.rgb * (pow(v2, 2.2) / y), s.a);
    }
    """#

    // ---- Mask selectors -------------------------------------------------------
    // Both return the selection as an opaque gray image (1 = selected).

    // range = (low, high, feather) on gamma-encoded luminance.
    static let luminanceMaskSource = #"""
    extern "C" [[stitchable]] float4 luminanceMaskKernel(coreimage::sample_t s, float3 range) {
        float v = pow(clamp(dot(max(s.rgb, 0.0), kLuma), 0.0, 1.0), 1.0 / 2.2);
        float f = max(range.z, 0.001);
        float w = smoothstep(range.x - f, range.x, v) * (1.0 - smoothstep(range.y, range.y + f, v));
        return float4(float3(w), 1.0);
    }
    """#

    // target = (L, a, b, range) in Oklab. Chroma differences count more than
    // lightness, so a sampled blue selects the sky in light and shade alike.
    static let colorMaskSource = #"""
    extern "C" [[stitchable]] float4 colorMaskKernel(coreimage::sample_t s, float4 target) {
        float3 lab = linearToOklab(max(s.rgb, 0.0));
        float3 d = lab - target.xyz;
        float distance = length(float3(d.x * 0.35, d.y, d.z));
        float range = max(target.w, 0.01) * 0.25;
        float w = 1.0 - smoothstep(range * 0.5, range, distance);
        return float4(float3(w), 1.0);
    }
    """#

    // Tints the selected area red for the mask overlay.
    static let maskOverlaySource = #"""
    extern "C" [[stitchable]] float4 maskOverlayKernel(coreimage::sample_t s, coreimage::sample_t mask) {
        float w = clamp(mask.r, 0.0, 1.0) * 0.55;
        return float4(mix(s.rgb, float3(1.0, 0.12, 0.1), w), s.a);
    }
    """#

    // ---- HSL band selection ---------------------------------------------------
    // Shows which pixels one HSL band affects, with the same weights as the mixer:
    // the band's colors stay, everything else turns dim gray.
    static let hslSelectionSource = #"""
    constant float kSelectHue[9] = { 0.51, 0.96, 1.92, 2.49, 3.40, 4.61, 5.06, 5.73, 6.79 };

    extern "C" [[stitchable]] float4 hslSelectionKernel(coreimage::sample_t s, float band) {
        float3 lab = linearToOklab(s.rgb);
        float chroma = length(lab.yz);
        float h = atan2(lab.z, lab.y);
        if (h < kSelectHue[0]) { h += 6.2831853; }
        int i = 0;
        for (int k = 0; k < 8; k++) { if (h >= kSelectHue[k]) { i = k; } }
        float t = smoothstep(0.0, 1.0, (h - kSelectHue[i]) / (kSelectHue[i + 1] - kSelectHue[i]));
        int b = int(band + 0.5);
        float w = 0.0;
        if (i == b) { w = 1.0 - t; }
        if ((i + 1) % 8 == b) { w += t; }
        w *= smoothstep(0.0, 0.06, chroma);
        float gray = dot(max(s.rgb, 0.0), kLuma) * 0.35;
        return float4(mix(float3(gray), s.rgb, clamp(w, 0.0, 1.0)), s.a);
    }
    """#

    // ---- Heal -----------------------------------------------------------------
    // Frequency-separation healing: the source's fine texture on the target's
    // low-frequency tone and color. The target's tone comes from a normalized blur
    // of the area around the spot (weighted sum / weights), so the blemish being
    // removed doesn't tint its own fill.
    static let healSource = #"""
    extern "C" [[stitchable]] float4 healKernel(coreimage::sample_t source, coreimage::sample_t sourceLow, coreimage::sample_t targetWeightedLow, coreimage::sample_t weightLow) {
        float3 targetLow = targetWeightedLow.rgb / max(weightLow.r, 1e-4);
        return float4(source.rgb - sourceLow.rgb + targetLow, 1.0);
    }
    """#
}
