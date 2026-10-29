# LightEditor — Design

## Goals and non-goals

This is a subscription-free, Lightroom-style RAW editor for hobbyists editing on vacation: shoot RAW, make quick color-focused edits, and get photos to people fast. It is personal first and possibly open source later.

**Goals**

- RAW 9 decoding wherever it is supported. Denoise and detail come from Apple's engine, not ours.
- Responsive editing: sliders never block, and every slow job shows visible progress.
- Lightroom-style single-photo editing focused on color grading.
- Copy/paste edits and bulk editing across a selection, like Photomator.
- Presets, including .cube LUTs.
- Apple Photos is the library: the original RAW plus a non-destructive edit recipe, synced by iCloud Photos.
- Next (M3): masking and AI. Local adjustments through gradient, brush, luminance and color masks, and AI subject, sky, people and object masks.
- Later (M4): seamless editing across iPhone, iPad and Mac, including on bad hotel Wi-Fi.

**Non-goals**

- Culling. A separate culling app handles triage.
- Pro features like tethering, catalogs outside Photos, or print modules.
- OS versions before 27.

## Principles

Use Apple APIs first, open source and open models second, and custom code only for the gaps. Run everything on-device and target the newest OS APIs. Performance overrides all of that: if an Apple API is too slow in a hot path, replace it and record why in the Decisions log.

| Component | Layer | Choice |
| --- | --- | --- |
| RAW decode, denoise, detail | Apple | `CIRAWFilter`, RAW 9 |
| Grading (WB, tone, HSL, LUT) | Apple + custom | Core Image built-ins fused into one GPU pass; custom Metal kernels only where no built-in fits (HSL mixer, color wheels) |
| Display, HDR | Apple | `MTKView` + Core Image extended range |
| Library, edit storage | Apple | PhotoKit, `PHAdjustmentData` |
| Local index | Open source | GRDB (SQLite) |
| Remote editing (M4) | Apple | Network.framework over peer-to-peer Wi-Fi, Bonjour, CryptoKit |
| Subject and person masks (M3) | Apple | Vision `GenerateForegroundInstanceMaskRequest`, `GeneratePersonInstanceMaskRequest` |
| Tap-to-mask (M3) | Apple | Vision `GenerateIterativeSegmentationRequest` (new in OS 27; point, box or scribble seeds) |
| Sky masks (M3) | Apple, then open model | Iterative segmentation seeded from the top of the frame; a dedicated sky model only if that falls short |
| Retouch, object removal (M3) | Open model | Inpainting model in Core ML (e.g. LaMa); first check whether Apple exposes anything public |
| .cube LUTs | Custom (small) | Parser feeding a Core Image color cube |
| Lightroom XMP import | Custom | Best-effort parameter mapping |

**Performance budgets** (proposed; the M0 spikes set the real numbers)

- Slider drag to updated preview within one display frame, at preview size.
- Opening a photo shows the embedded preview instantly, then swaps to the RAW 9 render once it's decoded.
- Nothing heavy on the main thread. Every job is cancellable and shows progress.
- The M1 iPad Pro is the floor. Every pipeline stage has signposts, and performance tests fail the build on regression.

## Platforms and targets

The app is one native SwiftUI multiplatform target (not Catalyst) with a minimum of iOS, iPadOS and macOS 27, because RAW 9 requires OS 27 ([Apple forums](https://developer.apple.com/forums/thread/843445)).

| Device | Supports OS 27 | Role |
| --- | --- | --- |
| iPhone 16 Pro (upgrading soon) | Yes | Editing on the go; primary importer when traveling |
| M1 iPad Pro | Yes ([iPadOS 27 list](https://tidbits.com/2026/07/20/the-real-system-requirements-for-os-27/)) | Main editing surface on trips; performance floor |
| M1 MacBook Pro | Yes | Home editing; Photos editing extension |

Cameras in scope are the Sony A7R V, the Fujifilm X-T5 and iPhone ProRAW.

## Render pipeline

Decode each RAW once with RAW 9, cache the result, and run all grading on the cache. RAW 9 is opt-in because it [costs performance](https://developer.apple.com/forums/thread/834485). It only changes demosaic and noise reduction, though, so it never needs to sit in the slider loop.

1. **Decode (slow, cached).** `CIRAWFilter` with `decoderVersion = .version9` when `supportedDecoderVersions` includes it, otherwise the best available. Outputs scene-linear, wide-gamut RGBA16F at preview and full sizes.
2. **Cache.** Keep the decoded intermediate in memory and on disk, keyed by photo ID + RAW-stage parameters (NR, detail, sharpening). Evict by LRU.
3. **Grade (fast, live).** Core Image built-ins on the cache, fused into one GPU pass, plus custom Metal kernels only where no built-in fits. Covers white balance, exposure, tone curve, HSL, color wheels, LUT and vignette. Target 60 fps on M1.
4. **Display.** `MTKView` in extended range, so HDR headroom is preserved.
5. **Export.** Full-res render in the background, HEIC or JPEG, through the same graph.

**Responsiveness rules** (the explicit fix for Nitro):

- Changing a RAW-stage slider shows the old decode instantly, re-decodes in the background, and swaps when ready.
- Every background job (decode, export, bulk apply) appears in a visible job tray with progress and cancel.
- Stale renders are cancelled, never queued. Only the latest slider value renders.
- Bulk edits render thumbnails first and full previews lazily.

White balance lives in the grade stage (decided in spike M0.5, `docs/spikes/white-balance.md`). `CITemperatureAndTint` maps the chosen white point onto the decoder's as-shot one, on the cached linear decode.

**Implementation notes**

- Custom kernels (tone, HSL mixer, color wheels, vignette, clipping) are Metal source strings compiled at runtime with `CIKernel.kernels(withMetalString:)`. They live in `EditorCore`, so `swift test` covers them, and each kernel is compiled from its own source (see the M0.3 spike for why).
- The HSL mixer and the color wheels work in Oklab/OkLCh. The tone operator (contrast, highlights, shadows, whites, blacks) is global, on luminance in a gamma-2.2 domain, and scales RGB by the luminance ratio. It is not a local (Lightroom-style) operator yet.
- Grade order: white balance → exposure and tone → presence (clarity, texture, dehaze) → tone curve (`CIColorCurves`, display-referred) → vibrance and saturation (built-ins) → HSL → color wheels → LUT (`CIColorCubeWithColorSpace` in sRGB, mixed by amount with `CIMix`) → perspective, straighten and crop → post-crop vignette → grain.
- The decode cache stores the preview decode (2560 px long edge) as an IOSurface-backed RGBA16F `CVPixelBuffer`, in memory and on disk. The disk key includes a format version, so decoder changes invalidate old entries.
- The preview grades only the pixels it shows. At Fit it grades the smallest of 256, 640 and 1280 px proxies of the decode (or the decode itself) that's still sharp on screen; while a slider drags or the photo pinches, it drops one size if full-quality frames take more than 16 ms, and the sharp frame follows 200 ms after the motion stops. Zoomed in past the decode, `TileCache` decodes 1024 px tiles of the original (half or full resolution) for the visible area only, nearest the middle first, and draws them over the enlarged decode, so the photo shows at once and sharpens as tiles arrive. For big sources (the 2560 px decode, or tiles), clarity's and dehaze's wide blurs come from a smaller copy, enlarged (`GradeInputs.presenceGuide`); texture's blur stays at full resolution. The histogram grades the 256 px proxy. Core Image encodes each frame on a background queue. A spinner by the title shows "Refining preview" or "Loading detail"; full-size saves and exports stay in the job tray.

## Edit model

An edit is a small, versioned recipe: a flat map of parameter name to value, plus a pinned decoder version. Rendering is a pure function of (original RAW, recipe), so every device produces the same image.

### Recipe sketch

```swift
struct Recipe: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var photoID: PhotoID               // SHA-256 of the original RAW bytes
    var decoder: DecoderPin            // e.g. RAW 9; pinned so renders match across devices and OS updates
    var params: [ParamKey: ParamValue] // flat map; absent key = default
    var stamps: [ParamKey: HLCStamp]   // per-parameter last-modified; unused until M3 merge, but always written
}

enum ParamValue: Codable, Sendable, Equatable {
    case scalar(Double)
    case point(x: Double, y: Double)   // color wheel offsets
    case curve([CurvePoint])
    case lut(LUTRef, amount: Double)   // LUTRef = content hash of the .cube file
    case crop(rect: NormalizedRect, angle: Double, aspect: AspectRatio?)
}
```

### Parameters by paste group (D0)

| Paste group | Parameters | Default in paste sheet | Stage |
| --- | --- | --- | --- |
| White balance | temperature, tint | On | Grade |
| Light | exposure, contrast, highlights, shadows, whites, blacks, clarity, texture, dehaze, tone curve | On | Grade |
| Color | vibrance, saturation, HSL mixer (8 hues × hue/sat/lum) | On | Grade |
| Grade | shadows/midtones/highlights/global wheels (hue, sat, lum), blending, balance | On | Grade |
| Film LUT | LUT ref, amount | On | Grade |
| Effects | vignette amount, midpoint, grain amount, grain size | On | Grade |
| Detail | noise reduction, color noise, sharpness, detail | On (re-decodes, slower) | RAW decode |
| Crop | rect, angle, aspect, vertical and horizontal perspective | Off (per photo) | Grade |

### Behaviors

- **Copy/paste.** Copy puts the recipe on the clipboard. Paste opens a sheet listing the paste groups, with everything but Crop ticked; untick what you don't want.
- **Bulk edit.** Select many photos, then either paste a recipe or move sliders in one of two modes: "Set values" (absolute) or "Adjust by (+/−)" (relative deltas, e.g. +0.3 EV to all). Applies through the job tray.
- **Match previous.** Apply the last edited photo's recipe to the next one, Lightroom-style.
- **Undo/redo and history.** Every committed slider change is a history step. Snapshots save named states.
- **Presets.** A preset is a partial recipe saved by name, applied with an amount.
  - Native JSON: exact, our own format.
  - .cube 3D LUT: exact and standard; covers film-look LUTs.
  - Lightroom XMP (`crs:`): best-effort import only. Adobe's tone and color math is proprietary, so values won't map 1:1.
- **Masks (V1).** Stored as recipes, not bitmaps: brush strokes as vector paths, AI masks as "model + target + refinement params". They are regenerated on each device to keep adjustment data small.

## Photos integration

Photos stores the original RAW plus our rendered result and recipe (`PHAdjustmentData`), and iCloud Photos syncs all three.

- **Edit:** `PHContentEditingInput` → render → `PHContentEditingOutput`, with our recipe as adjustment data (our format identifier + version). The original is never modified, and "Revert" in Photos still works.
- **Reopen on any device:** if `canHandle(adjustmentData)` matches our format, load the recipe and re-render from the original.
- **Foreign edits:** we can't read edits made in Photos itself or in other apps. Detect them and offer to start from the original.
- **Photos editing extension**, so edits can also start from inside Photos on the Mac (M2).
- **One edit per asset.** Virtual copies, if ever wanted, would be duplicated assets.

**Identity.** Our photo ID is the SHA-256 of the original RAW bytes. It works offline, before any upload, on every device. `PHCloudIdentifier` is Apple's [recommended durable cross-device identifier](https://developer.apple.com/forums/thread/833047). Cloud-to-local lookups are costly, so cache them.

## Remote editing (M4)

Remote editing replaces multi-device sync: there is no CloudKit, no recipe sync and no staged copies. One device shares its library, usually the iPhone, which has the photos and the faster chip. Another edits it, usually the iPad. The photos never leave the sharing device, and edits are saved straight into its Photos library, so there is nothing to reconcile.

**Connection**

- **Discovery:** Bonjour (`_lighteditor._tcp`). The sharing device advertises only while "Let nearby devices edit this library" is on.
- **Transport:** Network.framework TCP with `includePeerToPeer`, so the devices connect directly over peer-to-peer Wi-Fi (AWDL) with no router, internet or cellular.
- **Pairing:** each side makes a fresh Curve25519 key per connection, and both screens show the same six-digit code derived from the shared secret and both public keys. The person checks the codes match and taps Allow on both devices, as with Bluetooth numeric comparison; a device in the middle would produce different codes. Declining or cancelling on either side closes the connection.
- **Encryption:** after the handshake, every frame is ChaCha20-Poly1305 with a counter nonce per direction, so frames can't be replayed or reordered.
- **Messages:** request/response with progress events and pushes, as binary property lists (`Remote/RemoteMessages.swift`). Both devices must run the same protocol version.

**Who does what (hybrid)**

- **Sharing device (`RemoteHost`):** RAW decodes, AI masks (Vision), Remove fills from the full-resolution original, full-size saves to Photos, exports and bulk edits.
- **Editing device (`RemoteLibrary`):** stands in for Apple Photos. It receives each photo's decode once, as the decode cache's half-float bytes compressed with LZFSE (about 25–50 MB for a 2560 px preview), and grades it on its own GPU. Sliders never wait for the network.
- AI masks and fills come back as small PNGs and are cached like local ones. LUTs a recipe uses are sent along with saves, exports and bulk edits.
- The sharing device keeps its screen on while connected, but it doesn't have to stay in front (see below).

**Locking, switching apps, reconnecting**

iOS freezes a backgrounded app's networking within seconds, and there's no background mode for serving another device. So the link is expected to drop, and nothing depends on it staying up:

- **Trust:** each device has a long-term Curve25519 signing key in the Keychain (this device only). After the first approval both remember each other, and every handshake proves identity by signing both session keys. Trusted devices reconnect without asking; Devices › Allowed devices › Forget brings the code back.
- **Heartbeat:** both sides ping every 3 s, and 15 s with no bytes means lost. A frozen iPhone can leave its socket open while the app is suspended, so silence is the only reliable signal. Reads are chunked, so a long decode transfer counts as activity.
- **Why a link ended:** closed here, a goodbye from the peer (Disconnect or sharing turned off), or lost. Only "lost" reconnects.
- **iPad while the phone is away:** the open photo keeps editing on its cached decode, and photos opened before reopen from cached session info. Thumbnails come from cache. Requests wait for the next link and retry with the same idempotency key. Saves go through an outbox on disk (one entry per photo, newest wins) until the phone confirms, so they survive the iPad app being closed too. Pending saves also count as the stored edit when a photo reopens.
- **Reconnecting:** the iPad browses again and tries the phone with backoff (0.5 s up to 10 s, and immediately when either app returns to the front). On relaunch it restores the last session and reconnects on its own.
- **Phone:** `RemoteHost` lives for the whole session and runs each request key once, detached from the link that asked, so a retry joins the work in flight or gets its answer (small answers are kept 10 minutes). Work in flight gets about 30 s of background time to finish, then resumes when the app is opened again. The listener restarts when the app returns to the front.

**Simulators** don't register Bonjour services, so Debug simulator builds also listen on a fixed loopback port (52731) and offer "Simulator on this Mac" as a nearby device. This doesn't exist in device or Release builds.

**Spike questions**

- Real decode and transfer times over peer-to-peer Wi-Fi from an iPhone 16 Pro to the M1 iPad Pro.
- How fast does the iPad notice the phone locking on real hardware, and how fast does it reconnect after unlock?

## Risks and open questions

- [x] Are the A7R V and X-T5 supported by RAW 9? Yes: both list versions 7, 8 and 9 on macOS 27 and in the iOS 27 simulator (M0.2).
- [ ] RAW 9 decode time for a 61 MP A7R V file on the M1 iPad Pro. This sets the cache and preview-size strategy (M0.2).
- [ ] Can live grading on the cached intermediate hit one frame on M1 (M0.3)?
- [ ] What is the practical size limit for `PHAdjustmentData` (M0.4)?
- [x] Does white balance live in the RAW stage or the grade stage (M0.5)? The grade stage.
- [ ] RAW+JPEG pairs (Fuji): the app imports them as one asset (JPEG `.photo`, RAW `.alternatePhoto`) and always edits the RAW. OS 27 adds `PHAsset.originalResourceChoice`; check whether to honor it.
- [x] Job tray: always visible on iPad and Mac ("No jobs running" when idle), and only while jobs run on iPhone, where toolbar space is scarce.
- [ ] Photos asks permission on iOS each time an app modifies a photo. Bulk edits batch changes into one request; check how this feels on a device.
- [ ] Does `CIRAWFilter.scaleFactor` work on devices? It is ignored in the iOS 27 simulator (see the M0.2 spike).

## Lightroom XMP mapping (M2.5)

`XMPImporter` maps these `crs:` settings. Anything else with a non-default value is reported to the user as skipped.

| Lightroom (`crs:`) | Recipe key | Conversion |
| --- | --- | --- |
| Exposure2012 | light.exposure | EV, 1:1 |
| Contrast2012, Highlights2012, Shadows2012, Whites2012, Blacks2012 | light.* | −100…100, 1:1 (our tone math differs) |
| Temperature, Tint (only when WhiteBalance isn't "As Shot") | wb.temperature, wb.tint | Kelvin and tint, 1:1 |
| Vibrance, Saturation | color.vibrance, color.saturation | 1:1 |
| HueAdjustment*, SaturationAdjustment*, LuminanceAdjustment* (8 bands) | color.hsl.<band>.* | 1:1; bands match by name |
| ColorGrade{Shadow,Midtone,Highlight}{Hue,Sat} | grade.<range> | point = (cos hue, sin hue) × sat/100 |
| ColorGrade{Shadow,Midtone,Highlight}Lum | grade.<range>.lum | 1:1 |
| ColorGradeBlending, ColorGradeBalance | grade.blending, grade.balance | 1:1 |
| SplitToning{Shadow,Highlight}{Hue,Saturation}, SplitToningBalance | grade.* | as for ColorGrade |
| PostCropVignetteAmount, PostCropVignetteMidpoint | effects.vignette.* | 1:1 |
| LuminanceSmoothing, ColorNoiseReduction | detail.noiseReduction, detail.colorNoise | 0…100, 1:1 |
| Sharpness, SharpenDetail | detail.sharpness, detail.detail | Sharpness × 100/150; detail 1:1 |
| ToneCurvePV2012 | light.toneCurve | points ÷ 255 |
| Clarity2012, Texture, Dehaze | light.clarity, light.texture, light.dehaze | 1:1 (our local-contrast math differs) |
| GrainAmount, GrainSize | effects.grain.* | 1:1 |
| ColorGradeGlobalHue/Sat/Lum | grade.global | as for the other wheels |
| PerspectiveVertical, PerspectiveHorizontal | crop.perspective.* | 1:1 |

Not mapped: the camera profile and Look, per-channel curves, grain roughness and frequency, lens corrections and local adjustments.

## Decisions log

Add one line per decision: date, decision, reason.

- 2026-10: Editing flow first; sync deferred to M3.
- 2026-10: Apple APIs first, open source second, custom last; performance overrides.
- 2026-10: Don't force editing before iCloud upload.
- 2026-10-17: White balance runs in the grade stage on the cached decode (`CITemperatureAndTint` against the as-shot white point); the RAW filter stays out of the slider loop. See spikes/white-balance.md.
- 2026-10-17: Custom kernels are Metal source compiled at runtime, one source per kernel, so they live in `EditorCore` and `swift test` covers them. Batching kernels from one source corrupts render pipelines.
- 2026-10-17: Preview decodes are 2560 px RGBA16F `CVPixelBuffer`s, cached in memory and on disk. 100% view renders the full-size RAW lazily instead of caching a 480 MB buffer.
- 2026-10-17: The HSL mixer and color wheels work in Oklab, so neutrals stay neutral and hue bands blend without banding.
- 2026-10-17: Adjustment data is zlib-compressed recipe JSON, format `app.raweditor.recipe` v1 (kept after the rename to LightEditor, since it's stored in Photos). Scalars encode as bare numbers.
- 2026-10-17: The app has its own importer (RAW, RAW+JPEG pairs as one asset, JPEG/HEIC), because `simctl addmedia` can't add RAWs and SD-card imports on iPad need it anyway.
- 2026-10-17: Bulk edits render thumbnails first, then full renders committed in batches of 10, so iOS asks for permission once per batch.
- 2026-10-17: A `FolderLibrary` (folder of files plus JSON sidecars) implements the library protocol for tests, UI automation and Mac development, so none of them touch a real Photos library.
- 2026-10-17: Edits save when leaving a photo or when the app leaves the foreground, as a background job.
- 2026-10-17: Editing sliders and color wheels are custom controls with Nitro-style fine adjustment (pull away from the control), double-tap reset and press-and-hold "without this setting". On iOS they use UIKit recognizers, because SwiftUI drags inside a ScrollView either block or share scrolling. The drag math (`FineAdjust`) lives in EditorCore and is tested.
- 2026-10-17: Clarity, texture and dehaze are luminance local-contrast kernels against Gaussian blurs whose radii are fractions of the frame, so previews and exports match. Grain is a blurred `CIRandomGenerator` field scaled to the output frame.
- 2026-10-17: Perspective uses `CIPerspectiveTransform` with corners that only move outward, so the frame never shows empty corners and no extra scale-to-fill is needed.
- 2026-10-17: The Fujifilm film simulations ship as built-in presets with Fuji's names, approximated with our own controls (no Fuji LUTs). ImageIO's `{PictureStyle}` dictionary gives a RAF's FilmSimulation code (as label, value, default); the editor offers the matching preset.
- 2026-10-17: Auto tone sets the six Light sliders from a 256-bin luma histogram measured after white balance, going only 55% of the way on exposure and capping it at ±1.5 EV.
- 2026-10-17: Masking and AI move ahead of sync: M3 is now masking and AI, and sync becomes M4.
- 2026-10-17: Masks are `mask.<id>` recipe parameters holding a `MaskLayer`. They apply on the uncropped original before the LUT and geometry, so the Masks tab shows the full frame. AI masks are computed from the ungraded preview decode and cached per photo, so edits never invalidate them.
- 2026-10-17: Sky uses Vision's iterative segmentation seeded at sky-colored, smooth points along the top edge, checked to span the top. No model is bundled.
- 2026-10-17: Paste defaults to every group except Crop, including Detail and Masks (requested; Detail re-decodes, which is slower but expected).
- 2026-10-17: Retouch spots (`retouch.<id>`) apply to the original before grading. Remove uses LaMa (big-lama, Apache-2.0) in Core ML on a 512 px context crop, cached per photo by a hash of the spot chain. The model is built by `scripts/fetch-models.sh` and isn't checked in. Heal is frequency separation, with the source chosen by matching the ring around the spot pixel by pixel.
- 2026-10-17: Full-size renders (save, export, bulk) run one at a time through `RenderGate`, on a second low-priority `CIContext`. Two 61 MP renders at once can exceed an iPhone's memory limit, and a save on the shared context made the next photo's preview wait.
- 2026-10-17: LaMa's output is copied out of Core ML's pixel buffer by hand rather than read through Core Image, which caches by buffer and could return an earlier fill when Core ML reuses buffers. Fills run one at a time.
- 2026-10-17: Unsaved edits are written to a local draft after every change and restored when the photo reopens, since edits only reach Photos when a photo closes or the app goes to the background.
- 2026-10-17: Export offers sizes by megapixels (full, 24, 12, 6, 2) with file-size estimates from a 1024 px sample encode (0.8× its bytes per pixel, within about 15% on A7R V files), and saves straight to the library as a new photo.
- 2026-10-17: Split before/after is composited by the preview renderer at a fraction of the view's width, not baked into the image, so it follows zoom and pan without re-grading. "Saving" means the non-destructive edit on the original; "Exporting" means a separate file or photo, and job labels say which.
- 2026-10-17: Lens corrections (camera profile, on by default) and moiré reduction are RAW-stage parameters. AI masks and fills are cached per lens-correction setting, since it moves pixels.
- 2026-10-17: Auto straighten stores its method with the crop, not just the angle, so pastes and bulk edits re-detect per photo: camera level (Fujifilm tag 0x144D, landscape only), then Vision's horizon, then the pasted angle. Vision doesn't report horizons within about a degree of level, so detection runs at five known turns and takes the median.
- 2026-10-17: Remove fills come from the full-resolution original at up to 1024 px (LaMa "full"), with 512 px from the preview kept as "fast". The engine is part of each spot, so fills are recomputed when it changes.
- 2026-10-17: Sliders claim a drag only after 10 pt of movement within about 27° of horizontal, so vertical swipes that start on them scroll.
- 2026-10-24: The 1024 LaMa function runs on CPU+GPU only. The Neural Engine returns noise for it (iPhone 16 Pro and M4 Pro), and on the Mac `.all` doesn't load that function, which hid the bug until it ran on a phone. Fills that come back as noise are retried on the CPU, then reported as failed.
- 2026-10-25: Remote editing replaces multi-device sync (requested). The iPhone shares its library over peer-to-peer Wi-Fi and does the heavy work; the iPad grades the phone's decode locally (hybrid), so sliders never wait on the network. Pairing is numeric comparison of a six-digit code, approved on both devices. No CloudKit or recipe sync.
- 2026-10-25: Remote editing expects the link to drop (iOS suspends the phone's networking when it locks or switches apps): trusted devices reconnect silently via long-term identity keys, a 3 s heartbeat detects frozen peers, requests carry idempotency keys the phone runs once, and the iPad saves through a disk outbox. Local edits never wait on the link.
- 2026-10-26: iPads narrower than 1100 pt (portrait, Split View) use the stacked editor; the workspace's view bar and toolbar don't fit there. Retouch supports two-finger zoom and pan through a UIKit input layer, since SwiftUI can't cancel a one-finger drag when a second finger lands.
- 2026-10-26: "LaMa + diffusion" removal: LaMa fills first, then Stable Diffusion 1.5 inpainting re-imagines the area at strength 0.6. Diffusion alone invents new objects in the hole; started from LaMa it removes them and looks photographic (docs/spikes/diffusion-inpaint.md). Our own DPM-Solver++ sampler and precomputed prompt embeddings, so no SD runtime package, tokenizer or text encoder.
- 2026-10-28: Previews grade screen-sized proxies at Fit and cached tiles of the original when zoomed in, instead of the 2560 px decode and the lazy full-size RAW. On an M4 Pro: Fit 7 → 3 ms, the first 100% frame 800 ms (on the main thread) → about 10 ms of tile decode in the background, later zoomed frames 36 → 16 ms, histogram 24 → 4 ms. Rendering the whole image in the background while editing isn't needed: the screen never shows more pixels than it has, and full-size saves already run in the background.
- 2026-10-28: Zoomed-in previews take clarity's and dehaze's blurs from the 2560 px decode instead of blurring full-resolution pixels. On an iPhone 16 Pro those blurs made a zoomed frame 157 ms (2 ms without them); on an M4 Pro the frame drops from 17 to 3 ms. On the A7R V test photo the result differs by 1.4/255 on average and looks the same. Exports still blur at full resolution.
- 2026-10-28: Open source under MIT. Settings › Licenses bundles every license in full, and "LaMa + diffusion" asks once for agreement to the Stable Diffusion use restrictions (Open RAIL-M requires binding users to them); until then new removals default to LaMa.
