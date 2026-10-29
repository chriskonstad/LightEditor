# Spike M0.3: live grading latency

Status: **go on Mac; device numbers pending.**

## Setup

The preview decode is cached once as an IOSurface-backed RGBA16F `CVPixelBuffer`, wrapped as a `CIImage` so Core Image samples it on the GPU without a copy. Every slider change rebuilds the `GradeGraph` (cheap: no pixels are touched) and hands it to `PreviewRenderer`.

`PreviewRenderer` is pull-based:

- Setting an image only marks the `MTKView` dirty.
- The view draws at most once per display refresh.
- At most one frame is in flight; a newer image replaces any pending one.

So slider input can never queue stale renders.

## Numbers

`PerformanceTests.testGradePreviewFrame` renders a busy recipe at 2560×1707 into an RGBA16F buffer. The recipe uses white balance, the tone kernel, the tone curve, vibrance, HSL, color wheels and vignette.

| Machine | Average per frame |
| --- | --- |
| M4 Pro Mac | **3.0 ms** (5 runs, RSD 9%) |
| M1 iPad Pro | to measure |
| iPhone 16 Pro | to measure |

A 120 Hz frame is 8.3 ms, so on this Mac there is plenty of headroom. On M1 the expectation is roughly 2–4× slower, which is still within one 60 Hz frame. Confirm with the `DisplayFrame` signposts in Instruments.

## Findings

- **Kernels must be compiled from separate Metal sources.** Kernels created together by one `CIKernel.kernels(withMetalString:)` call get their render pipelines mixed up when rendered in the same `CIContext`: the second kernel rendered returned the first one's output. Each kernel is now compiled from its own source string, with a shared helper prefix. There's a regression test for this in `RenderTests`.
- Runtime compilation of all five kernels takes about 0.35 s. The app warms the kernels up on a background task at launch.
- The 100% view renders the full-resolution RAW lazily (`CIRAWFilter` output, region of interest only), so it never caches a 480 MB full-size buffer. It is slower per frame than Fit. That's acceptable for inspecting focus, but measure it on M1.
