# Contributing to LightEditor

Thanks for helping. LightEditor is a small, opinionated app maintained in spare time, so a short note first saves everyone effort.

## Before you start

- **Bugs:** open an issue with the device, OS version, camera and file type (ARW, RAF, DNG, JPEG, HEIC), and steps to reproduce. Don't attach photos you don't want public; a description or a crop is usually enough.
- **Features:** open an issue to discuss it before writing code. The app aims to do quick, color-focused travel edits well, not to match Lightroom feature for feature. Culling, catalogs outside Apple Photos, tethering and printing are out of scope.
- **Security problems** (for example in the device-to-device link): report them privately through the repository's security advisory page instead of a public issue.

## Ground rules

These come from [docs/DESIGN.md](docs/DESIGN.md) and [CLAUDE.md](CLAUDE.md), which has the full list:

1. **Performance first.** Sliders never block. Never decode a RAW on the main thread. Work longer than about 100 ms goes through `JobCenter` so it shows in the job tray, and can be cancelled.
2. **Apple APIs first,** open source and open models second, custom code only for the gaps.
3. **Latest OS only.** The minimum is iOS, iPadOS and macOS 27. Don't add availability checks or fallbacks.
4. **Everything on-device.** No servers, network calls, analytics or telemetry. No new third-party dependencies without discussing them first.
5. **The recipe is the source of truth.** Rendering is a pure function of the original and the recipe; views hold no hidden edit state. Recipes are versioned: never break decoding of old ones, add a migration.
6. **Thin views.** Logic lives in `Packages/EditorCore` behind protocols, so it's testable without Photos access.

## Making a change

1. Fork, then create a branch from `main`.
2. Set up the build as in the [README](README.md#building). The Mac and the Simulator need no signing.
3. Edit `project.yml`, never the `.xcodeproj`, then run `xcodegen generate`.
4. Add or update tests in `Packages/EditorCore/Tests`. Recipe encode/decode/migrate/merge, paste groups, `.cube` parsing and XMP mapping must stay covered.
5. Run `scripts/test.sh` and `scripts/build.sh`; both must pass.
6. If you change a design decision, update `docs/DESIGN.md` and add a line to its Decisions log.
7. Open a pull request that says what changed, why, and how you tested it. Include timings from a real device for anything performance-related; Simulator timings don't count.

Test with a simulator's Photos library or a folder of sample RAWs, never your own library. [docs/spikes/simulator-tooling.md](docs/spikes/simulator-tooling.md) explains how.

## Style

- Swift 6 language mode with strict concurrency.
- Match the surrounding code: its naming, comment density and idioms. Comments explain why, not what.
- Wrap new pipeline stages in `os_signpost` (see `Render/Signposts.swift`).

## License

By contributing, you agree that your contribution is licensed under the project's [LICENSE](LICENSE).
