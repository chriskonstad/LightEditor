# Spike: depth range masks (and luminance masks)

Status: built 2026-11-27 (model only: the user prefers computing every mask ourselves over depth or mattes stored by some iPhones, so all cameras behave alike). Question: can masks select by
distance from the camera, as Lightroom's Depth Range does, and how should the mask
tools improve generally?

## What Apple provides (iOS, iPadOS and macOS 27.1 SDKs)

- **No monocular depth estimation API.** The SDK has no Vision request, Core Image
  filter or Photos API that estimates depth from an ordinary photo. Vision's requests
  include person, foreground and sky segmentation, saliency and horizon detection;
  depth appears only as an optional input (`AVDepthData` passed to a request handler).
- **Embedded depth in iPhone photos.** ImageIO reads disparity or depth stored in
  JPEG, HEIF and DNG files (`CGImageSourceCopyAuxiliaryDataInfoAtIndex` with
  `kCGImageAuxiliaryDataTypeDisparity` or `…Depth`; `AVDepthData(fromDictionaryRepresentation:)`),
  and Core Image loads it with `CIImage(contentsOf:options: [.auxiliaryDisparity: true])`.
  iPhones record it for Portrait photos, and recent ones for ordinary photos with a person or pet
  in them. Its resolution is low (around 768 × 576) and it only exists for iPhone shots.
- **Semantic mattes in iPhone photos.** `CIRAWFilter` exposes `portraitEffectsMatte`
  and skin, hair, teeth, glasses and sky mattes for ProRAW files that have them; ImageIO
  reads the same mattes from HEIC. That could give iPhone photos Lightroom's people
  parts (skin, hair, teeth) for free.
- Sony ARW and Fujifilm RAF files carry no depth.

So for the cameras this app is mostly for, depth has to come from a model.

## Open models

| Model | License | Core ML | Size | Speed (Apple's figures) | Output |
| --- | --- | --- | --- | --- | --- |
| Depth Anything V2 Small, `apple/coreml-depth-anything-v2-small` | Apache-2.0 | Yes, published by Apple | 49.8 MB (F16) / 99.2 MB (F32) | ~31–34 ms on iPhone 12 Pro Max and 15 Pro Max, 33 ms on M1 Max (Neural Engine) | Relative depth, per image |
| Depth Pro, `apple/DepthPro` | apple-amlr (research only) | No (PyTorch) | ~1.9 GB | 0.3 s for 2.25 MP on a GPU | Metric depth, sharper edges |

Depth Anything V2's Base and Large checkpoints are CC-BY-NC, so only Small fits an
open-source app. Depth Pro's license rules it out, and it's far too large anyway.

## Proposal

1. **A "Depth range" mask part** (`MaskShape.depth(near:far:feather:)`), stored like
   the luminance range: numbers only, never a bitmap. Each device regenerates the
   depth map, as it does for the AI masks.
2. **The depth source**, in order: the photo's embedded disparity when there is one
   (iPhone), else Depth Anything V2 Small run once per photo through Vision's
   `CoreMLRequest` on the decoded preview, cached with the other AI masks. Its output
   is about 518 px on the long side, so upsample it with an edge-aware (guided) filter
   against the photo, so edges follow the subject rather than the blocky map.
3. **The panel**: Near, Far and Smoothness sliders over a near-to-far bar (like
   `LuminanceRangeBar`), plus tap-to-pick: tap the photo and the range centers on that
   point's depth. While adjusting, show the depth map as the overlay, as Lightroom does.
4. **Combining**: the existing Intersect operation already gives "subject, but only
   the far one" or "sky, but only near the horizon".
5. **Model delivery**: like LaMa, built by `scripts/fetch-models.sh` and bundled
   (adds about 50 MB to the app). Needs a yes first, since it's a new model download.

Relative depth is normalized per image, so a pasted depth range means "the same
fraction of this photo's depth", which is what you want for a batch from one scene.

## Luminance masks today

Luminance range and color range parts already exist (Masks › + › Luminance range /
Color range), with Dark end, Bright end and Smoothness sliders over a luminance bar.
Gaps worth closing alongside depth:

- **Tap-to-pick for luminance**, as color range already has: tap a tone and the range
  centers on it.
- **Drag handles on the range bar**, instead of only sliders.
- **Show the luminance map** as the overlay while adjusting the range.
- **Intersect by default** when adding a range part to an existing mask (Lightroom's
  "Intersect with" flow), since a range on its own is rarely what you want.

## Questions for a device spike

- Do iPhone ProRAW DNGs from the camera app include disparity (ImageIO says DNG can
  carry it), or only HEIC?
- Depth Anything V2 Small timing and memory on the M1 iPad Pro (the performance floor).
- How stable relative depth is across similar frames, for batch pasting.
