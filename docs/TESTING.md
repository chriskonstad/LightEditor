# Testing

How LightEditor is tested, which command to run for which change, and how to read a failure. Everything here runs on a Mac with the repo's own fixtures; nothing touches a real Photos library.

## Which command

| Command | What runs | Time (M4 Pro) |
| --- | --- | --- |
| `scripts/test-fast.sh` | EditorCore unit tests, goldens and property tests. Prints only failures. | ~5 s warm, 1–2 min cold |
| `scripts/test-fast.sh --filter <regex>` | One suite or test, e.g. `--filter RenderGolden` | seconds |
| `scripts/test.sh --raw` | Unit tests plus the real-RAW tests on `Fixtures/`: decode, Vision masks, camera looks, RAW goldens, XCTest performance runs | ~1.5 min |
| `scripts/test-ui.sh` | UI audits and screenshots on iPhone SE and iPad mini simulators | ~8–12 min |
| `scripts/test-all.sh` | All of the above with the AI-model tests, performance budgets and the app builds, with a summary | ~15 min |

A unit run that prints nothing for 5 minutes (`TEST_STALL_SECONDS`) is stopped as hung and lists the tests that started but never finished. Tests that set process-wide state (`RawDecoder.remote`, peer links) nest under the serialized `RemoteSuites`; put any new one there too, or it can deadlock other suites behind `RenderGate.fullSize`.

**The inner loop is `scripts/test-fast.sh` (`just test-fast`).** Run `scripts/test-all.sh` (`just check`) before merging or shipping a feature. `just test-ui` wraps `scripts/test-ui.sh`.

| You changed… | Run |
| --- | --- |
| Recipe model, codec, paste, presets, XMP, `.cube` | `scripts/test-fast.sh` |
| Grading, kernels, masks, retouch, geometry | `scripts/test-fast.sh --filter "Render\|Mask\|Retouch"`, then the whole fast suite |
| RAW decoding, `RawDecoder`, camera looks, lens corrections | `scripts/test.sh --raw` |
| Anything on a hot path (decode, grade, display, export) | `EDITORCORE_PERF_BUDGETS=1 EDITORCORE_RAW_FIXTURES=$PWD/Fixtures scripts/test-fast.sh --filter PerformanceBudget`, and real-device timings |
| SwiftUI views, layout, text, controls | `scripts/test-ui.sh`, then look at the screenshots |
| `project.yml`, entitlements, the app target | `scripts/build.sh` |

## EditorCore unit tests

`Packages/EditorCore/Tests/EditorCoreTests`, run by `swift test`. Most are Swift Testing (`@Test`); `PerformanceTests` is XCTest for its `measure` baselines.

Tests that need something big are skipped unless it's there:

- `EDITORCORE_RAW_FIXTURES=<folder>` (`scripts/test.sh --raw` sets it to `Fixtures/`) runs the decode, Vision, straighten, camera-look, RAW golden and RAW performance tests.
- `Models/` (from `scripts/fetch-models.sh`) runs the real LaMa and diffusion tests. They take about 40 s, so `scripts/test-fast.sh` skips them unless you pass `--models`. A git worktree has no `Models/`; `scripts/test-ui.sh` links the main checkout's, or run `ln -s <main checkout>/Models Models`.

### Recipe format

The recipe is stored in every edited photo and must decode forever.

- `RecipeCompatibilityTests` pins the encoding. `Fixtures/recipe_v1_all_kinds.json` holds one of every value kind (scalars, wheels, curves, LUTs, crop with auto straighten, every mask shape, every retouch kind, a reset). The test checks that it decodes to the same recipe and that today's encoder writes the same bytes. If it fails, the encoding changed: bump `Recipe.currentSchemaVersion`, add a migration in `RecipeCodec`, keep the old file, and record the new version's (`EDITORCORE_RECORD=1`). It also checks that every older version has a migration and a fixture, and that the parameter catalog is consistent. The kitchen sink is the look only, so this also proves the look's stored form is unchanged; `Fixtures/recipe_v1_output_block.json` pins the separate `output` block (border, canvas, watermark with text and a logo) the same way.
- `RecipePropertyTests` runs codec, clamping and paste invariants on 200 seeded random recipes: round trips, Set-mode paste copies the source, paste never touches unselected groups, pasting twice equals once, paste groups partition the catalog. A failure names its seed; `RecipeGenerator(seed:)` rebuilds the case. New parameters are covered automatically.

### Render goldens

Rendering is a pure function of (original, recipe), so `RenderGoldenTests` grades a synthetic 96 × 64 chart (hues across, brightness up past 1.0, a gray ramp) with 18 recipes, one per tool area plus an "everything" case. Each result is averaged into 12 × 8 blocks and compared with `Fixtures/Goldens/<case>.json`: at most 0.01 difference per block channel and 0.002 on average, in linear light. That passes GPU-to-GPU float noise and fails on any visible change. `caseChangesTheChart` makes sure no case is a silent no-op.

`RawGoldenTests` does the same for each RAW in `Fixtures/` at 384 px, at a looser tolerance, to catch decoder changes (an OS update to RAW 9, a changed RAW-stage default) that would change how existing edits look.

On a mismatch the message names the worst block, and PNGs of the actual render and of the expected and actual grids are written to `build/test-artifacts/render-goldens/`. If the change is intended:

```sh
EDITORCORE_RECORD=1 scripts/test-fast.sh --filter RenderGolden    # synthetic chart
EDITORCORE_RECORD=1 scripts/test.sh --raw                         # also the RAW goldens
```

then review the JSON diff and commit it with the change. When you add a grading parameter or stage, add a case to `RenderGoldenTests.cases`.

### Performance

Two layers, because the Simulator and the Mac aren't the devices that matter (CLAUDE.md):

- **`PerformanceTests`** (XCTest `measure`) times decode, grade and export. Their baselines are meant to be recorded per device in Xcode; on a Mac via `swift test` they only print numbers. Device baselines are still to record (M1.11).
- **`PerformanceBudgetTests`** are coarse regression guards for local runs, enabled with `EDITORCORE_PERF_BUDGETS=1` (`scripts/test-all.sh` runs them as their own stage, after the parallel unit run, since GPU contention from the model tests made a 5 ms frame take 500 ms). Each prints a `BUDGET` line with the median of several runs and fails over a budget set at several times what an M4 Pro measures, with room for an M1: graph build on the slider path (0.2 ms, budget 5 ms), a 2560 px frame with a mask (7 ms, budget 60 ms), the recipe codec, and with RAW fixtures a cold preview decode (1.4 s idle, 6.5 s with the machine busy; budget 15 s) and a full-size HEIC export (7.3 s idle, 17 s busy; budget 40 s). They catch an accidental re-decode, a CPU fallback or a slow graph build, not a 10% slip; for that, measure on a device.

## UI tests

`UITests/` (target `LightEditorUITests`, scheme `LightEditorUITests`), run by `scripts/test-ui.sh`.

`ScreenAuditTests` launches the app on a folder library (`-FixtureLibrary`, a fresh copy of one ARW and one JPEG from `Fixtures/` for each test) and walks the main screens: library, Settings, Devices, the editor and each tab (scrolled too) including Finish with the watermark switched on and an open color wheel, a radial mask, the More menu, crop, retouch and export. It does that at the default text size and at the largest accessibility size, and in landscape on iPad. On each screen it:

- saves a screenshot to `build/ui-screenshots/<device>/<orientation>-<size>/NN-<screen>.png`, so you (or an agent) can look at every screen after a UI change;
- checks touch targets of 44 × 44 pt or more on the buttons and fields we lay out (system switches, sliders, list rows and bar buttons are left to Apple's audit, since their hit areas are larger than their frames);
- checks that nothing is laid out past the window's sides outside a scroll view;
- runs Apple's accessibility audit (`performAccessibilityAudit`). Clipped text and hit regions are enforced; text a scroll view cuts off at its edge isn't. Contrast, Dynamic Type support, descriptions and traits are reported as warnings.

The app is dark-only, so there's no light-mode pass.

Each configuration's findings go to `audit.txt` next to its screenshots:

- **FAIL**: new, enforced. These fail the test.
- **known**: listed in `UITests/audit-baseline.txt`. The audit was added to an app that already had findings; the baseline lets it catch regressions without blocking on those. Fix one and the report lists its line under "Fixed"; delete the line, or re-record.
- **warn**: reported only.

```sh
scripts/test-ui.sh                        # iPhone SE (3rd generation) and iPad mini, in parallel
scripts/test-ui.sh --all                  # plus iPhone 18 Pro Max and iPad Pro 13-inch
scripts/test-ui.sh --devices "iPhone 17e"
scripts/test-ui.sh --only testScreensAtDefaultTextSize
scripts/test-ui.sh --keep --no-build      # reuse the simulators and the last build
scripts/test-ui.sh --record-baseline      # accept the current findings as known
```

Only re-record the baseline when a finding is accepted on purpose (say so in the commit), never to make a regression go away. The script creates its own simulators (named "LightEditor UITest …", on the newest iOS runtime that supports each device) and deletes them afterwards unless `--keep`, so it never disturbs a simulator you're using. A failed run doesn't collect simulator diagnostics, which took ten minutes.

`FeatureTourTests` is a demo, not an audit: `scripts/ui-tour.sh` (`just ui-tour`) runs it in a throwaway simulator and records `build/ui-tour/<device>/tour.mp4` plus a screenshot per step: canvas backgrounds with a strong vignette, the color wheels opened with their sliders, the mask overlay hiding on adjust, and the Finish tab (border, the color picker, a typed watermark, a 4:5 canvas). `testLogoWatermark` imports an SVG logo through `-WatermarkLogo` (the same import the Finish tab runs, without the file picker) to check SVG conversion on iOS. Run it to look at a UI change; `scripts/test-ui.sh` skips it. It brings controls on screen by tapping their labels, since a scroll drag can grab a control (one moved a tone-curve point).

Both scripts check `xcodebuild`'s own exit status before testing; a failed build used to fall through to testing the previous build.

When you add a screen, add it to the walk and give its controls accessibility identifiers (`area.control`, as in `editor.export`). For anything the walk can't reach, the Mac's `-SnapshotTo` and the iOS tooling in `docs/spikes/simulator-tooling.md` still work.

## Before merging

1. `scripts/test-all.sh` passes. It prints a PASS/FAIL table with times and logs in `build/test-all/`.
2. After a UI change, look at the screenshots in `build/ui-screenshots/` for the screens you touched, at both text sizes.
3. Performance-sensitive changes still need real-device numbers (CLAUDE.md).
