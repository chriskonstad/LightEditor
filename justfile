# LightEditor tasks. Run `just` to list them, and `just --show <recipe>` to see what
# one runs. Recipes are thin wrappers: the real logic lives in scripts/, so everything
# here also works without just.

set shell := ["zsh", "-euo", "pipefail", "-c"]
# Recipe lines get their arguments as "$@" too, so arguments with spaces survive.
set positional-arguments

derived := "build/DerivedData"
mac_app := derived / "Build/Products/Debug/LightEditor.app"
sim_app := derived / "Build/Products/Debug-iphonesimulator/LightEditor.app"
# The Mac app's sandbox container, where a folder library has to live.
mac_container := env("HOME") / "Library/Containers/com.chriskonstad.lighteditor/Data"

# List the recipes.
default:
    @just --list --unsorted

# --- project ---

# Generate LightEditor.xcodeproj from project.yml.
[group('project')]
generate:
    xcodegen generate

# Generate the project and open it in Xcode.
[group('project')]
open: generate
    open LightEditor.xcodeproj

# Delete build output (build/, the package's .build) and the generated project.
[group('project')]
clean:
    rm -rf build Packages/EditorCore/.build LightEditor.xcodeproj

# --- test ---

# EditorCore unit tests on the Mac; pass a filter to run a subset, e.g. `just test-core RecipeCodec`.
[group('test')]
test-core filter="":
    swift test --package-path Packages/EditorCore {{ if filter == "" { "" } else { "--filter " + quote(filter) } }}

# The full test script (scripts/test.sh); flags pass through, e.g. `just test --raw --ios`.
[group('test')]
test *flags:
    scripts/test.sh "$@"

# Unit tests plus the real-RAW tests on Fixtures/ (decode, Vision, camera looks, performance).
[group('test')]
test-raw:
    scripts/test.sh --raw

# Unit tests on the Mac and in an iOS simulator (IOS_DESTINATION overrides the simulator).
[group('test')]
test-ios:
    scripts/test.sh --ios

# --- quality gates ---
# Lint, format and other pre-ship checks go here (scripts to come). Add them to
# `check` so one command runs every gate.

# Every gate that must pass before a pull request or a TestFlight upload.
[group('quality')]
check: test build

# --- build ---

# Build for macOS, the iOS Simulator and iOS devices (scripts/build.sh).
[group('build')]
build:
    scripts/build.sh

# Build the Mac app (Debug).
[group('build')]
build-mac: generate
    xcodebuild -scheme LightEditor -destination 'platform=macOS' -derivedDataPath {{ derived }} build -quiet

# Build for iOS devices without signing, to check that it compiles.
[group('build')]
build-ios: generate
    xcodebuild -scheme LightEditor -destination 'generic/platform=iOS' -derivedDataPath {{ derived }} build -quiet CODE_SIGNING_ALLOWED=NO

# Build for the iOS Simulator (Debug).
[group('build')]
build-sim: generate
    xcodebuild -scheme LightEditor -destination 'generic/platform=iOS Simulator' -derivedDataPath {{ derived }} build -quiet

# --- run ---

# Build and launch the Mac app. It uses the Mac's Photos library: prefer run-mac-fixtures.
[group('run')]
run-mac: build-mac
    open -n {{ quote(mac_app) }}

# The folder is copied into the app's sandbox container, the only place it can read.
# Extra args pass to the app, e.g. `just run-mac-fixtures Fixtures -OpenFirstAsset YES`.
[doc("Build and launch the Mac app against a folder library instead of Photos.")]
[group('run')]
run-mac-fixtures folder="Fixtures" *app_args: build-mac
    #!/bin/zsh
    set -euo pipefail
    library={{ quote(mac_container) }}/$(basename {{ quote(folder) }})
    mkdir -p {{ quote(mac_container) }}
    # macOS guards other apps' containers; the terminal needs App Management or Full
    # Disk Access (System Settings › Privacy & Security) to write into it.
    { rm -rf "$library" && cp -R {{ quote(folder) }} "$library"; } || {
        echo "Couldn't copy into $library. Allow your terminal App Management or Full Disk Access in System Settings › Privacy & Security." >&2
        exit 1
    }
    shift
    open -n {{ quote(mac_app) }} --args -FixtureLibrary "$library" "$@"

# --- simulator ---
# `device` is a simulator UDID or name (`xcrun simctl list devices booted`). The
# default, "booted", picks one booted simulator; name one when several are booted.

# Build, install and launch the app in a simulator.
[group('simulator')]
sim-run device="booted": build-sim
    xcrun simctl install {{ quote(device) }} {{ quote(sim_app) }}
    xcrun simctl launch {{ quote(device) }} com.chriskonstad.lighteditor

# Goes through the app's own importer, since `simctl addmedia` rejects ARW and RAF.
[doc("Import a folder of RAWs into a simulator's Photos library (grants Photos access first).")]
[group('simulator')]
sim-import folder="Fixtures" device="booted": build-sim
    xcrun simctl install {{ quote(device) }} {{ quote(sim_app) }}
    xcrun simctl privacy {{ quote(device) }} grant photos com.chriskonstad.lighteditor
    xcrun simctl launch --terminate-running-process {{ quote(device) }} com.chriskonstad.lighteditor -ImportFolder "$(cd {{ quote(folder) }} && pwd)"

# Grant a simulator's Photos access to the app.
[group('simulator')]
sim-grant device="booted":
    xcrun simctl privacy {{ quote(device) }} grant photos com.chriskonstad.lighteditor

# --- models ---

# Build the AI removal models into Models/: LaMa and Stable Diffusion inpainting (20-40 min, needs uv).
[group('models')]
fetch-models:
    scripts/fetch-models.sh

# Build only the LaMa model (about 100 MB).
[group('models')]
fetch-models-lama:
    SKIP_DIFFUSION=1 scripts/fetch-models.sh

# Symlink Models/ from another checkout (default: the main worktree), so a git worktree builds with AI removal.
[group('models')]
link-models from="":
    #!/bin/zsh
    set -euo pipefail
    src={{ quote(from) }}
    [[ -n "$src" ]] || src="$(git worktree list --porcelain | sed -n '1s/^worktree //p')/Models"
    [[ -d "$src" ]] || { echo "No models at $src"; exit 1; }
    [[ "${src:A}" != "${PWD:A}/Models" ]] || { echo "This is the checkout that holds the models"; exit 0; }
    [[ ! -e Models || -L Models ]] || { echo "Models/ already exists here and isn't a symlink"; exit 1; }
    ln -sfn "$src" Models
    echo "Models -> $src"

# --- release (maintainers) ---

# Build a Release build and install it on a paired iPhone or iPad (default: the first connected iPhone).
[group('release')]
install-device udid="":
    scripts/install-device.sh "$@"

# Archive the iOS app and upload it to TestFlight; flags pass through (--internal-only, --no-upload, --mac).
[group('release')]
testflight *flags:
    scripts/testflight.sh "$@"

# Archive the Mac app and upload it to TestFlight.
[group('release')]
testflight-mac *flags:
    scripts/testflight.sh --mac "$@"

# Submit an uploaded build for App Store review: `just submit ios|macos <build> [version]`.
[group('release')]
submit platform build *version:
    scripts/submit-app-store.py "$@"

# Tag an App Store release on GitHub, e.g. `just tag-release 1.0.5 <commit> "iOS build …"`.
[group('release')]
tag-release *args:
    scripts/tag-release.sh "$@"
