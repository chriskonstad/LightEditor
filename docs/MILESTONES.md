# Milestones

Work top to bottom. Each task has acceptance criteria; check the box and add a one-line note when it's done. Each milestone ends in a gate, which is a go/no-go before starting the next.

Spikes live in `Spikes/` and write their findings to `docs/spikes/<slug>.md`. They answer questions; they don't ship code to `App/`.

## M0 — Scaffold and spikes

- [x] **M0.1 Scaffold.** Create the XcodeGen `project.yml` with one SwiftUI multiplatform app target (iOS, iPadOS, macOS 27), the `Packages/EditorCore` Swift package, and `scripts/build.sh` + `scripts/test.sh`.
  - Accept: it builds for iOS and macOS, and `swift test` passes with a placeholder test.
  - Done 2026-10-17: `project.yml`, `Packages/EditorCore`, `scripts/build.sh` and `scripts/test.sh`. Builds for macOS, the iOS simulator and iOS devices (unsigned).
- [ ] **M0.2 Spike: RAW 9 decode.** Load an A7R V ARW, an X-T5 RAF and a ProRAW DNG from Photos. Log `supportedDecoderVersions`, then time decodes at preview size (2560 px long edge) and full size, with peak memory, on all three devices.
  - Accept: `docs/spikes/raw9-decode.md` has a table of camera × device × size → time and memory, plus a recommended preview size.
  - Partial: Mac numbers and support confirmed in `docs/spikes/raw9-decode.md` (A7R V and X-T5 both support RAW 9; preview size 2560 px). Device numbers are still to measure. The simulator ignores `scaleFactor`.
- [ ] **M0.3 Spike: live grading latency.** Decode once to a cached RGBA16F image. Drive exposure, a tone curve and a color cube through Core Image into an EDR `MTKView` from a slider. Measure frame time with signposts on the M1 iPad Pro.
  - Accept: p50 and p95 frame times are recorded, with a go/no-go against the one-frame budget. If it's a no-go, name the slow stage and a fix.
  - Partial: 3.0 ms per 2560 px frame on an M4 Pro Mac, so a go there (`docs/spikes/live-grading.md`). The M1 iPad Pro number is still needed.
- [ ] **M0.4 Spike: Photos round trip.** Write an edit through `PHContentEditingOutput` with a JSON recipe as adjustment data on the iPhone. Confirm it reopens on the iPad and Mac after iCloud sync, and that Revert in Photos works. Find the practical `PHAdjustmentData` size limit.
  - Accept: `docs/spikes/photos-roundtrip.md` with results and the size limit.
  - Partial: the single-device round trip works in the simulator, and recipes are under 4 KB (`docs/spikes/photos-roundtrip.md`). Cross-device iCloud sync and Revert in Photos still need real devices.
- [x] **M0.5 Spike: where white balance lives.** Measure whether changing `CIRAWFilter` temperature/tint triggers full re-decode cost, and compare it to WB in the grade stage on linear data.
  - Accept: a decision, recorded in the DESIGN.md Decisions log.
  - Done: the grade stage (`docs/spikes/white-balance.md`, Decisions log).

**Gate:** decode cost and slider latency are understood, and an edit round-trips between devices through Photos.

## M1 — Single-photo editor

- [x] **M1.1 Recipe model.** Implement `Recipe`, `ParamKey`, `ParamValue`, paste groups, a JSON codec, a schema version and the migration hook.
  - Accept: unit tests for round-trip encode/decode, defaults, and decoding a v1 fixture.
  - Done: `Recipe/`, with tests in `RecipeTests` (round trip, defaults, the v1 fixture, newer-schema rejection, migration hook).
- [x] **M1.2 Render pipeline.** Build `RawDecoder` (actor), `DecodeCache` (memory + disk LRU), `GradeGraph` (recipe → CIImage graph) and `PreviewRenderer` (EDR `MTKView`), with stale-render cancellation and signposts throughout.
  - Accept: a slider drag never queues more than one pending render, and the M0.3 latency target holds.
  - Done: `RawDecoder`, `DecodeCache`, `GradeGraph`, `PreviewRenderer` (at most one frame in flight), with signposts. Latency on M1 is unmeasured.
- [x] **M1.3 JobCenter and job tray.** An observable job model (progress, cancel, label) with the tray UI from UI-SPEC.
  - Accept: decode, re-decode and export all appear in the tray and can be cancelled.
  - Done: decode, re-decode, iCloud download, save, export, import and bulk jobs all show in the tray with cancel.
- [x] **M1.4 Library browser.** A PhotoKit grid filtered to RAW assets, with albums and Recents. Tapping a photo opens the editor. No culling features.
  - Accept: smooth scrolling on the iPad with a large library, and thumbnails from PhotoKit's caching image manager.
  - Done: RAW, All Photos, Favorites, Recently Edited and user albums, with lazy `AssetList` and `PHCachingImageManager` thumbnails. Not yet tried on a large library.
- [x] **M1.5 Custom kernels.** The HSL mixer (8 hues) and three-way color wheels as Metal Core Image kernels.
  - Accept: unit tests on synthetic images show the expected hue, saturation and luminance shifts with no banding.
  - Done: Oklab HSL mixer and color wheels, with tests for hue, saturation and luminance shifts, neutrals, and a banding check.
- [x] **M1.6 iPhone editor UI.** Tabs for Light, Color, Grade, Detail and Presets per UI-SPEC, plus compare (before/after), undo/redo and the embedded-preview-first open.
  - Accept: matches UI-SPEC, and every control writes to the recipe.
  - Done and driven in the iPhone 18 Pro simulator: tabs, compare, undo/redo, embedded-preview-first open.
- [x] **M1.7 iPad and Mac editor UI.** Inspector layout, filmstrip, view bar (Fit, 100%, clipping, split before/after), history list with snapshots, and Mac keyboard shortcuts.
  - Accept: matches UI-SPEC on both platforms.
  - Done: inspector, filmstrip, view bar (Fit/100%/clipping/split), history with snapshots, Mac sidebar and keyboard shortcuts. The iPad was checked in the simulator; on the Mac only the layout and rendering were checked, with a folder library.
- [x] **M1.8 Remaining tools.** Tone curve, vignette, and crop/straighten with aspect presets.
  - Accept: each is in the recipe, rendered, and covered by tests.
  - Done: tone curve editor, vignette, and crop/straighten with aspect presets, all tested.
- [x] **M1.9 Save to Photos.** Save as adjustment data, reopen from Photos, and detect foreign edits.
  - Accept: the M0.4 round trip works from the real app.
  - Done: saves on leaving the photo or the app; reopens from adjustment data; foreign edits are detected (`adjustmentFormatIdentifier`) with a notice.
- [x] **M1.10 Export.** HEIC/JPEG at chosen sizes through the share sheet, as a background job.
  - Accept: a full-res export matches the preview's color.
  - Done: HEIC/JPEG at full, 4096, 2048 or 1080 px; Share, or Save to Photos as a new photo. Uses the same graph as the preview.
- [ ] **M1.11 Performance tests.** XCTest performance tests for decode, grade and export, with recorded device baselines.
  - Accept: a regression beyond the threshold fails the test.
  - Partial: `PerformanceTests` cover decode, grade and export. Device baselines still need recording in Xcode.

**Gate:** it replaces Photomator for single-photo editing at home.

## M2 — Copy/paste, bulk edit, presets

- [x] **M2.1 Copy/paste.** Copy edits, then paste through a group sheet. Everything but Crop is ticked by default (changed from "Detail and Crop off" at the user's request).
  - Accept: tests for paste-group filtering.
  - Done: in the editor and on library selections, with `PasteTests`.
- [x] **M2.2 Bulk edit.** Multi-select in the library, paste to N photos, and the "Set values" vs "Adjust by (+/−)" modes. Runs through JobCenter, rendering thumbnails first.
  - Accept: pasting to 50 photos never blocks the UI.
  - Done: paste, Set/Adjust sliders, presets and reset across a selection via `BulkEditor` (thumbnails first, batched commits, cancellable), tested on 12 photos. The 50-photo run on a device is untested.
- [x] **M2.3 Match previous.**
  - Accept: one action applies the previous photo's recipe.
  - Done: in the editor's More menu and the Mac Photo menu.
- [x] **M2.4 Presets.** Save, apply and adjust the amount of native JSON presets. Add a .cube import, parser and tests. Preset tiles render live from the current photo.
  - Accept: the parser handles common .cube sizes, and preset thumbnails render asynchronously.
  - Done: built-in and saved JSON presets with Amount, .cube import into the Film LUT picker or as a preset, and live tiles. Parser tested at sizes 2 to 65 and with DOMAIN rescaling.
- [x] **M2.5 XMP import.** Best-effort mapping from `crs:` parameters, with the mapping table documented in DESIGN.md.
  - Accept: tests on sample XMP files, and unmapped parameters are reported to the user.
  - Done: mapping table in DESIGN.md, `XMPImporterTests`, and unmapped settings are reported in the import alert.
- [ ] **M2.6 Photos editing extension.** On the Mac first; on iOS if it's worthwhile.
  - Accept: you can edit from inside Photos, with the same recipe format.

**Gate:** day-to-day editing, including batches, is faster than with the current tools.

- [x] **M2.7 Editing refinements** (requested 2026-10-17).
  - Done:
    - Nitro-style fine sliders and darktable-style fine color wheels;
    - double-tap reset; press and hold to see the photo without a setting;
    - draggable before/after split;
    - 65:24 (XPan) and custom crop ratios; vertical and horizontal perspective;
    - HSL by-property view;
    - Clarity, Texture, Dehaze, Grain and a Global grading wheel; Auto tone;
    - Fujifilm film-simulation presets, plus a "Shot as …" banner from RAF metadata.
  - Tests: `NewControlTests` (presence, grain, perspective, global wheel, auto tone, film-simulation codes, fine-adjust math). Drag gestures were checked in the simulators.

## M3 — Masking and AI

Masks are stored as recipes, never bitmaps: shapes, brush strokes as vector paths, and AI masks as "model + seeds". Each device regenerates them, so adjustment data stays small. Apple APIs come first, so OS 27 Vision covers the AI masks (see DESIGN.md).

- [x] **M3.1 Mask model.** `MaskLayer` with components (add, subtract, intersect, invert) and local adjustments, stored as `mask.<id>` recipe parameters, plus a Masks paste group.
  - Accept: codec, paste and preset tests; old recipes still decode.
  - Done: `Recipe/Mask.swift`, with `MaskModelTests`.
- [x] **M3.2 Mask rendering.** Linear and radial gradients, brush strokes, luminance range and color range, combined and blended with local adjustments in the grade graph.
  - Accept: tests show each shape affects only its area, and previews match exports.
  - Done: `MaskRenderer`, with `MaskRenderTests`.
- [x] **M3.3 AI masks.** Subject (foreground instances), people, background, sky, and tap-to-select object (iterative segmentation), computed with Vision on the cached decode and cached per photo.
  - Accept: tests on real photos on the Mac; masks regenerate after a recipe round trip; the job tray shows model downloads and slow masks.
  - Done: `AIMaskStore`, `VisionMaskTests` and `docs/spikes/ai-masks.md`. Vision models don't run in the iOS simulator (no Neural Engine), so device timings are still to measure.
- [x] **M3.4 Masks UI.** A Masks tab with the mask list, add menu, components, local sliders and a mask overlay. On-canvas handles for gradients, brush painting with size, feather and erase, and tap-to-select.
  - Accept: driven in the iPhone and iPad simulators.
  - Done: radial, linear, brush and the mask sliders were driven in the simulators, and masks survive a save to Photos and reopen. AI masks there show Vision's simulator error.
- [x] **M3.5 Adaptive presets.** Presets that carry AI masks, e.g. "Sky: deepen blue", which regenerate on each photo.
  - Done: five built-ins (Sky: deep blue, Sky: sunset glow, Subject: pop, Background: soften, People: warm skin) in their own Presets section. Saved presets can include the Masks group.
- [x] **M3.6 Retouch.** Spot heal and AI object removal. Check Apple's public APIs first, then an open inpainting model in Core ML (ask before adding a model).
  - Done:
    - OS 27 has no public inpainting API, so the app uses LaMa (big-lama, Apache-2.0), converted with `scripts/fetch-models.sh`. It takes about 0.12 s per 512 px fill on the M4 Pro's Neural Engine.
    - Remove, Heal and Clone spots are recipes, applied before grading.
    - Heal and Clone pick a source automatically by ring matching, and the source can be dragged.
    - Driven on the iPad simulator. Remove gives clean results.
  - Known: Heal on narrow, busy areas can still pick a poor source; drag it. Remove is the default for that reason.
- [x] **M3.7 Higher-quality removal.** LaMa runs at up to 1024 px on a crop of the full-resolution original (a two-function Core ML package: "full" 1024, "fast" 512, shared weights), so removals up to about 400 px across fill at native resolution. Each spot records its engine.
- [x] **M3.9 LaMa + diffusion.** Remove can run LaMa, then Stable Diffusion 1.5 inpainting at strength 0.6, with "Try another" for a new variation. See `docs/spikes/diffusion-inpaint.md`.
  - Done: models converted by `scripts/fetch-models.sh` (about 850 MB), our own DPM-Solver++ sampler with tests, a real-model test.
  - Next: device timing and memory on iPhone 16 Pro and M1 iPad Pro, and whether the Neural Engine is safe for these models.
- [x] **M3.8 Auto straighten.** The camera's level (Fujifilm maker note) for upright landscape frames, else Vision's horizon detection, else the pasted angle. Pasting re-detects per photo.
  - Spike question: does Sony record a roll angle anywhere ExifTool can't see? The A7R V files tested only carry coarse orientation.
  - Spike question: the X-T5 recorded 1.0° where Vision found 0.5°. Is Fuji's roll rounded to whole degrees? Check more RAFs.
  - Spike question: does the RAW 9 decoder's noise reduction use a learned model? It isn't documented as AI denoise; compare against an ML denoiser before building one.

## M4 — Remote editing (replaces sync)

See "Remote editing" in DESIGN.md. Edit the iPhone's photos from the iPad over peer-to-peer Wi-Fi, with the heavy work on the phone.

- [x] **M4.1 Link.** Bonjour discovery, TCP with peer-to-peer Wi-Fi, a six-digit code shown on both devices, approval on both, then encrypted request/response.
  - Done: `Remote/PeerLink.swift` and friends. Tests cover the code, a device in the middle, replays, a loopback round trip, decline and remote errors.
- [x] **M4.2 Remote library.** The iPad's library, decoder, AI masks, Remove fills, saves, exports and bulk edits go through the phone.
  - Done: `RemoteHost` and `RemoteLibrary`, with an end-to-end loopback test (bit-exact decode, save lands in the phone's library).
- [x] **M4.3 UI.** Devices sheet (share toggle, nearby devices), the approval sheet with the code, and a banner while connected.
  - Done: driven on an iPhone and an iPad simulator. Connect, approve on both, browse, open a RAF (decoded on the phone), Auto, save back through the phone, disconnect.
- [x] **M4.4 Reconnection.** The phone can lock or switch apps: trusted devices reconnect silently, a heartbeat detects a frozen phone, the iPad keeps editing offline and saves through a disk outbox, and the phone runs each request once.
  - Done: tests for a drop mid-save (saved once, edit kept, photo reopens offline), the outbox across restarts, and a frozen peer. In the simulators: killed the phone app mid-session, reset a photo on the iPad offline (save queued), relaunched the phone, and the iPad reconnected and saved with no prompts; relaunching both apps restores the session.
- [ ] **M4.5 Real devices.** iPhone 16 Pro sharing, M1 iPad Pro editing, no Wi-Fi network.
  - Accept: connects without a router; opening a 61 MP ARW takes under about 5 s; sliders are as fast as local; saves land in the phone's Photos; locking the phone or switching apps mid-edit loses nothing, and the iPad reconnects within a few seconds of unlocking.
