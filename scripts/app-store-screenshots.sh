#!/bin/zsh
# App Store screenshots for iPhone 6.9", iPad 13" (landscape) and the Mac, from a
# folder library of the two fixtures without people in them. See
# docs/app-store/screenshots.md for the set and the sizes.
#
#   scripts/app-store-screenshots.sh              all three
#   scripts/app-store-screenshots.sh --ios        iPhone and iPad only
#   scripts/app-store-screenshots.sh --mac        Mac only
#   scripts/app-store-screenshots.sh --no-build   reuse the last builds
#
# Output: build/screenshots/{iphone,ipad,mac}/NN-<screen>.png. iOS shots come from
# AppStoreScreenshotTests in throwaway simulators with a clean status bar; Mac shots
# from one Debug launch each with -SnapshotTo. Never touches a Photos library.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD

ios=1 mac=1 build=1
while (( $# )); do
    case $1 in
        --ios) mac=0 ;;
        --mac) ios=0 ;;
        --no-build) build=0 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "Unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

out=$root/build/screenshots
photos=(Fixtures/DSCF2030.raf Fixtures/DSC04921.ARW)
work=$root/build/screenshots-work
rm -rf $work && mkdir -p $work

if (( ios )); then
    devices=("iPhone 18 Pro Max" "iPad Pro 13-inch (M5)")
    folders=(iphone ipad)
    derived=build/UITests
    library=$work/library
    mkdir -p $library && cp -c $photos $library/

    typeset -A udids
    cleanup() {
        for udid in ${(v)udids}; do
            xcrun simctl shutdown $udid >/dev/null 2>&1 || true
            xcrun simctl delete $udid >/dev/null 2>&1 || true
        done
    }
    trap cleanup EXIT

    if (( build )); then
        echo "Building for testing…"
        xcodegen generate --quiet
        set +e
        xcodebuild build-for-testing -scheme LightEditorUITests -destination 'generic/platform=iOS Simulator' \
            -derivedDataPath $derived -quiet > build/ui-build.log 2>&1
        rc=$?
        set -e
        (( rc == 0 )) || { grep -E "error:" build/ui-build.log | head -20; echo "Build failed (build/ui-build.log)" >&2; exit 1; }
    fi

    destinations=()
    for device in $devices; do
        runtime=$(xcrun simctl list runtimes -j | python3 -c "
import json, sys
device = sys.argv[1]
runtimes = [r for r in json.load(sys.stdin)['runtimes']
            if r['platform'] == 'iOS' and r['isAvailable'] and any(t['name'] == device for t in r['supportedDeviceTypes'])]
print(max(runtimes, key=lambda r: [int(p) for p in r['version'].split('.')])['identifier'] if runtimes else '')
" "$device")
        [[ -n $runtime ]] || { echo "No iOS runtime supports \"$device\"" >&2; exit 1; }
        udid=$(xcrun simctl create "LightEditor UITest $device" "$device" "$runtime")
        udids[$device]=$udid
        xcrun simctl boot $udid
        xcrun simctl bootstatus $udid >/dev/null
        xcrun simctl status_bar $udid override --time 9:41 --batteryState charged --batteryLevel 100 \
            --cellularBars 4 --wifiBars 3 --dataNetwork wifi
        destinations+=(-destination "id=$udid")
    done

    echo "Capturing on: ${(j:, :)devices}"
    set +e
    TEST_RUNNER_UITEST_LIBRARY=$library \
    TEST_RUNNER_UITEST_OUTPUT=$work/ios \
    xcodebuild test-without-building -scheme LightEditorUITests -derivedDataPath $derived \
        $destinations -only-testing:LightEditorUITests/AppStoreScreenshotTests \
        -maximum-concurrent-test-simulator-destinations ${#devices} \
        -collect-test-diagnostics never -quiet > $work/ios.log 2>&1
    rc=$?
    set -e
    grep -E "error:|\[FAIL\]" $work/ios.log | sed 's/^.*: error: /error: /' | sort -u | head -20 || true
    (( rc == 0 )) || { echo "iOS capture failed ($work/ios.log)" >&2; exit 1; }

    for i in {1..${#devices}}; do
        dest=$out/${folders[$i]}
        rm -rf $dest && mkdir -p $dest
        cp $work/ios/${devices[$i]// /-}/app-store/*.png $dest/
    done
fi

if (( mac )); then
    container=$HOME/Library/Containers/com.chriskonstad.lighteditor/Data
    app=build/DerivedData/Build/Products/Debug/LightEditor.app
    if (( build )); then
        echo "Building the Mac app…"
        xcodegen generate --quiet
        xcodebuild -scheme LightEditor -destination 'platform=macOS' -derivedDataPath build/DerivedData build -quiet \
            2>&1 | grep -E "error:" | head -20 || true
    fi
    [[ -d $app ]] || { echo "No Mac build at $app" >&2; exit 1; }
    # A sandboxed app reads only its own container. The terminal needs App Management
    # or Full Disk Access to write there (System Settings › Privacy & Security).
    library=$container/Shots
    { rm -rf $library && mkdir -p $library && cp $photos $library/; } || {
        echo "Couldn't copy into $library. Allow your terminal App Management or Full Disk Access." >&2
        exit 1
    }
    dest=$out/mac
    rm -rf $dest && mkdir -p $dest

    # name, then the launch arguments (the same set as AppStoreScreenshotTests).
    shots=(
        "01-light|-OpenAsset DSCF2030.raf -AutoTone YES -EditorTab light"
        "02-color|-OpenAsset DSC04921.ARW -EditorTab color -ScrollTo section.hsl -SetParams color.hsl.red.hue=12,color.hsl.red.saturation=-18,color.hsl.red.luminance=10,color.hsl.orange.saturation=25,color.vibrance=15"
        "03-grading|-OpenAsset DSCF2030.raf -ApplyPreset Teal&orange -EditorTab color -ScrollTo section.grading -OpenWheel shadows"
        "04-presets|-OpenAsset DSCF2030.raf -ApplyPreset Velvia -AutoTone YES -EditorTab presets"
        "05-effects|-OpenAsset DSC04921.ARW -ApplyPreset B&W -EditorTab effects -SetParams effects.vignette.amount=-35,effects.grain.amount=30"
        "06-masks|-OpenAsset DSCF2030.raf -AutoTone YES -EditorTab masks"
        "07-finish|-OpenAsset DSC04921.ARW -ApplyPreset ClassicChrome -EditorTab finish -SetParams finish.border.width=5,finish.border.bottom=12"
    )
    for shot in $shots; do
        name=${shot%%|*}
        args=(${(z)${shot#*|}})
        # Preset names with spaces are written without them above.
        args=(${args//Teal&orange/Teal & orange})
        args=(${args//ClassicChrome/Classic Chrome})
        snaps=$container/tmp/snaps-$name
        rm -rf $snaps && mkdir -p $snaps
        echo "Mac: $name"
        $app/Contents/MacOS/LightEditor -FixtureLibrary $library -ResetState YES -ApplePersistenceIgnoreState YES \
            -SnapshotTo $snaps -HideSidebar YES $args >/dev/null 2>&1 &
        pid=$!
        sleep 25
        kill $pid 2>/dev/null; wait $pid 2>/dev/null || true
        latest=$(ls -t $snaps/snapshot-*.png 2>/dev/null | head -1)
        [[ -n $latest ]] && cp $latest $dest/$name.png || echo "  no snapshot for $name" >&2
    done
fi

rm -rf $work
echo "Screenshots: ${out#$root/}/"
for dir in $out/*(/); do
    for png in $dir/*.png(N); do
        printf '  %s  %s\n' "${png#$root/}" "$(sips -g pixelWidth -g pixelHeight $png | awk '/pixel/ {printf "%s ", $2}')"
    done
done
