# LightEditor

A subscription-free, Lightroom-style RAW editor for iPhone, iPad and Mac. It is for hobbyist travel editing: shoot RAW, make quick color-focused edits, and get photos to people fast. Apple Photos is the library. The code is open source, so keep it clean enough for strangers to read.

Maintainer-only notes (release workflow, test hardware) live in `CLAUDE.local.md`, which is git-ignored and may not exist in your checkout.

Read these before working:

- `docs/DESIGN.md`: architecture, decisions, and open questions.
- `docs/MILESTONES.md`: ordered tasks with acceptance criteria. Work the first unchecked task unless told otherwise.
- `docs/UI-SPEC.md`: screens, layout and interaction.

## Current focus

**The editing flow comes first.** M0 through M2 are built: spikes, the single-photo editor, copy/paste, bulk edit and presets. **Next is M3, masking and AI** (local adjustments, AI subject/sky/people/object masks, then retouch).

Multi-device sync is dropped: **remote editing (M4)** replaces it. The iPhone shares its library over peer-to-peer Wi-Fi and does the heavy work, and the iPad edits it (see "Remote editing" in `docs/DESIGN.md`). Don't build CloudKit or recipe sync. Recipes still carry a photo ID and per-parameter timestamps.

Models aren't in git; `scripts/fetch-models.sh` rebuilds them.

## Principles, in priority order

1. **Performance is critical.** Sliders never block, and every slow job is visible and cancellable. If an Apple API is too slow in a hot path, replace it, and record why in the Decisions log in `docs/DESIGN.md`.
2. **Apple APIs first, open source and open models second, custom code only for the gaps.**
3. **Latest APIs only.** The minimum OS is iOS, iPadOS and macOS 27. Never add availability checks or fallbacks for older OSes.
4. **Everything runs on-device.** No servers, no analytics, no telemetry.

## Stack

- Swift 6 language mode with strict concurrency.
- One native SwiftUI multiplatform app target. No Mac Catalyst.
- `CIRAWFilter` with the RAW 9 decoder, Core Image for grading, and Metal for custom kernels and display (`MTKView`, extended range / EDR).
- PhotoKit for the library and for non-destructive edits (`PHContentEditingOutput` + `PHAdjustmentData`).
- GRDB (SQLite) for any local index, only when needed.
- No other third-party dependencies without asking first.

## Repo layout

```
App/                      SwiftUI app, shared across iOS, iPadOS and macOS
Packages/EditorCore/      Swift package with all logic, testable via `swift test`
  Recipe/                 Recipe model, codec, versioning, paste groups
  Render/                 RawDecoder, DecodeCache, GradeGraph, kernels, export
  Presets/                Native JSON presets, .cube parser, XMP mapping
  Library/                PhotoKit adapters behind protocols
  Jobs/                   JobCenter (the visible job tray model)
UITests/                  XCUITest screen audits (scripts/test-ui.sh)
Spikes/                   Throwaway spike apps; never shipped
docs/                     Design, milestones, UI spec, spike reports
project.yml               XcodeGen spec; never hand-edit the .xcodeproj
justfile                  Common tasks (`just` lists them); thin wrappers over scripts/
```

The views stay thin. Logic lives in `EditorCore` behind protocols so it can be unit-tested without Photos access.

## Build and test

The `justfile` at the root holds the common tasks; `just` lists them by group. The recipes are thin wrappers around `scripts/` and the commands below.

```sh
just test-fast              # inner loop: EditorCore tests, failures only (~5 s)
just test-ui                # UI audits + screenshots in throwaway simulators
just check                  # everything before a merge or ship (scripts/test-all.sh, ~15 min)
just test-core [filter]     # plain swift test, optionally filtered
just test                   # scripts/test.sh; also `just test-raw`, `just test-ios`
just build                  # scripts/build.sh: macOS, iOS Simulator and iOS device builds
just build-mac              # or build-ios, build-sim
just run-mac-fixtures       # the Mac app against Fixtures/, never the real Photos library
just sim-import [folder] [device]   # import RAWs into a simulator's Photos library
just link-models            # in a git worktree: symlink Models/ from the main checkout
```

Without `just` (`brew install just`), the raw commands are:

```sh
swift test --package-path Packages/EditorCore
xcodegen generate
xcodebuild -scheme LightEditor -destination 'platform=macOS' build
xcodebuild -scheme LightEditor -destination 'generic/platform=iOS' build
```

Performance numbers only count from real devices. The Simulator is fine for UI and logic, never for RAW 9 or render timing.

`docs/TESTING.md` says which test to run for which change. In short: `just test-fast` (`scripts/test-fast.sh`) is the inner loop (about 5 s, prints only failures); `just test-ui` audits every main screen in fresh simulators for clipped text, small touch targets and off-screen layout, and saves screenshots to `build/ui-screenshots/` to look at after a UI change; `just check` runs everything before a merge. Render and recipe goldens fail on purpose when output or the stored format changes; re-record them only when the change is intended.

## Testing

Test in a simulator's local Photos library or a folder library, never a real one. Remote editing can be tested with two simulators: turn on sharing on one, and the other lists "Simulator on this Mac" (simulators can't use Bonjour, so Debug simulator builds use loopback port 52731). `docs/spikes/simulator-tooling.md` covers importing RAWs into a simulator (`-ImportFolder`), the axe shim for Xcode 27, and running the Mac app against a folder (`-FixtureLibrary`).

## Performance rules

- Never decode a RAW on the main thread.
- Decode once into a cached scene-linear RGBA16F intermediate. Only RAW-stage parameters (noise reduction, detail, sharpening) trigger a re-decode; grading changes never do.
- Use one Metal-backed `CIContext` for everything interactive (`RenderContext.shared`). Full-size saves and exports run one at a time through `RenderGate`, queued by `RenderPriority`, on their own `RenderContext.fullSize`.
- Coalesce slider input to the display refresh rate, and cancel stale renders instead of queueing them.
- Wrap every pipeline stage (decode, grade, display, export) in `os_signpost`.
- Keep `XCTest` performance tests with device baselines for decode, grade and export.
- Any background work longer than about 100 ms goes through `JobCenter`, so it shows up in the job tray.

## Conventions

- The recipe is the single source of truth, and rendering is a pure function of (original RAW, recipe). Views hold no hidden edit state.
- Border and watermark are output settings, not part of the look: stored in the edit's separate `output` block, rendered in the preview and exports, never in the image saved to Photos (`Recipe.look`) or in presets. They copy and paste as their own group.
- The recipe is `Codable` and versioned. Never break decoding of old recipes; add a migration instead.
- Write tests for recipe encode/decode/migrate/merge, paste-group filtering, .cube parsing and XMP mapping.
- Mark uncertain Apple API behavior as a spike question in `docs/MILESTONES.md` rather than guessing. Spike results go in `docs/spikes/<slug>.md`.
- Keep `docs/DESIGN.md` current when a decision changes, and add a one-line entry to its Decisions log.

## Don't

- Build CloudKit or recipe sync; remote editing replaces it.
- Store masks as bitmaps in the recipe. Masks are recipes (shapes, strokes, AI model + seeds), regenerated on each device.
- Use Catalyst, deprecated APIs, or compatibility shims for old OS versions.
- Add dependencies, network calls or telemetry without asking.
- Hand-edit the `.xcodeproj`.
