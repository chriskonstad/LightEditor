# Spike M0.2: RAW 9 decode

Status: **partial.** Mac numbers are in. iPhone 16 Pro and M1 iPad Pro numbers still need a run on the devices (`scripts/test.sh` with `EDITORCORE_RAW_FIXTURES` set, or Instruments with the `Decode` signposts).

## Support

`CIRAWFilter.supportedCameraModels(with: .version9)` lists 69 models on macOS 27, including:

- "Sony Alpha ILCE-7R V"
- "Fujifilm X-T5" (and X-T50)

For both test files, `supportedDecoderVersions` returns `["7", "8", "9"]`. The default `decoderVersion` is **8**, so RAW 9 has to be requested explicitly. That matches "RAW 9 is opt-in" in DESIGN.md.

`downloadResources(timeout:completionHandler:)` (new in OS 27) returned immediately with no error on this Mac. The resources were already present. On a fresh device it may download, so the decoder awaits it before every RAW 9 decode (`RawDecoder.downloadResources`).

## Timings

Measured on an M4 Pro Mac (macOS 27, Xcode 27). The decode is rendered into an RGBA16F buffer; times include the render.

| Camera | File | Decoder | 2560 px preview | Full size |
| --- | --- | --- | --- | --- |
| A7R V | DSC04319.ARW, 9504×6336 | RAW 8 | 0.37 s | 0.77 s |
| A7R V | DSC04319.ARW | RAW 9 | 1.44 s (first), ~0.9–1.4 s after | 2.67 s |
| X-T5 | DSCF2030.RAF, 7728×5152 | RAW 8 | 0.22 s | 0.30 s |
| X-T5 | DSCF2030.RAF | RAW 9 | 1.38 s (first), ~0.4 s after | 1.57 s |

From `PerformanceTests` on the same Mac:

- RAW 9 preview decode of the A7R V file: about 1.4 s average, with a **peak of about 1.15 GB** physical memory during the decode.
- A full-resolution HEIC export with a busy recipe: about 3.1 s.

## Recommendation

- **Preview size: 2560 px** long edge. It is big enough to fill an iPad Pro and a Retina Mac window at Fit, and the cached RGBA16F buffer is about 35 MB.
- The memory peak during a 61 MP decode is large, so decodes are serialized (the `RawDecoder` actor) and never run two at a time.
- Re-opening a photo uses the on-disk decode cache: about 10 ms instead of seconds.

## Simulator caveat

In the iOS 27 simulator, `CIRAWFilter.scaleFactor` is **ignored**. The output reports the scaled extent but contains the top-left corner of the full-size image. The Mac honors `scaleFactor`. In the simulator only, `RawDecoder` decodes at full size and downscales with Lanczos (`#if targetEnvironment(simulator)`). Confirm on devices that `scaleFactor` works there; if it doesn't, remove the condition.
