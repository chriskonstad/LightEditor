# Spike M3.3: AI masks with Vision

Status: **go.** Apple's OS 27 Vision covers subject, people, tap-to-select and, with a heuristic, sky. No third-party model is needed for M3.

## APIs

| Mask | API | Notes |
| --- | --- | --- |
| Subject | `GenerateForegroundInstanceMaskRequest` | All instances. The raw output is 512×512; `generateScaledMask(for:scaledToImageFrom:)` gives clean edges at the analysis size. |
| People | `GeneratePersonInstanceMaskRequest` | Per-person instances (4 runners found). The cat photo reported one "person" but an empty mask. |
| Background | Subject, inverted | Shares the subject computation and cache entry. |
| Object (tap) | `GenerateIterativeSegmentationRequest(seedPoint:)` | New in OS 27, SAM-like. It also takes `seedBox:` and `seedScribbleBuffer:`. Its model is a downloadable asset: `assetStatus` was `.notReady` on first use, and `downloadAssets()` took 3.7 s. |
| Sky | Iterative segmentation from sky-like seed points | See below. Apple has no public sky model. |

## Timings (M4 Pro Mac, 1536 px analysis image)

- Subject: 20–100 ms. The first call in a process takes about 1.9 s (model load).
- People: 0.1–0.6 s.
- Tap-to-select: about 60 ms per seed after the first (2.8 s on first use).

Analysis runs on the photo's ungraded 2560 px preview decode, downscaled to 1536 px. Results are cached per photo and shape, in memory and as 8-bit PNGs in Caches, so reopening a photo reuses them.

## Sky

Seeding iterative segmentation with a single point near the top selected the whole sunset sky down to the horizon, and did better than a seed box along the top. Without care, though, the same seed on a street photo selected a shop sign.

`AIMaskStore.sky` therefore:

1. Samples patches along the top 5% of a 64 px copy of the image and keeps those that are bright (mean > 0.2), smooth (std dev < 0.09), not foliage green, and sky-colored. Sky-colored means blue-leaning, bright neutral, or a saturated warm sunset; a dull brick wall fails.
2. Runs iterative segmentation from up to three of the best seeds and unions the results.
3. Accepts the result only if it spans more than 30% of the frame's top edge. Otherwise it reports "No sky found".

Results on the fixtures: the X-T5 sunset gives 100% sky coverage at the top and 0% at the bottom, and the A7R V street photo correctly finds no sky. If skies with heavy cloud texture fail in practice, the fallback is a dedicated sky segmentation model in Core ML (ask before adding one).

## Still to check

- Running in the iOS simulator. Vision models may need the Neural Engine, which the simulator lacks.
- Timings on the M1 iPad Pro and iPhone 16 Pro.
- Whether exports should rerun Vision at a higher resolution for finer hair and edge detail. Today the 1536 px mask is stretched.
