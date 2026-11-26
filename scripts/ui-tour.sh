#!/bin/zsh
# A scripted tour of recent features (UITests/FeatureTourTests.swift) in a throwaway
# simulator, with screenshots and a screen recording, to look at after a UI change.
#
#   scripts/ui-tour.sh                         iPhone 18 Pro
#   scripts/ui-tour.sh --device "iPad Pro 13-inch (M5)"
#   scripts/ui-tour.sh --no-build              reuse the last UI test build
#
# Output: build/ui-tour/<device>/tour/NN-<step>.png and build/ui-tour/<device>/tour.mp4.
# Uses its own simulator, never one already booted, and a copy of Fixtures/ as a
# folder library, never a Photos library.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD

device="iPhone 18 Pro" build=1
while (( $# )); do
    case $1 in
        --device) shift; device=$1 ;;
        --no-build) build=0 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "Unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

derived=build/UITests
out=$root/build/ui-tour
dir=$out/${device// /-}
rm -rf $dir $out/tour.xcresult && mkdir -p $dir

if [[ ! -e Models ]]; then
    main=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
    [[ -d $main/Models ]] && ln -s "$main/Models" Models
fi

library=$root/build/ui-tour-library
rm -rf $library && mkdir -p $library
cp -c Fixtures/DSC04921.ARW Fixtures/DSCF2763.jpg $library/

runtime=$(xcrun simctl list runtimes -j | python3 -c "
import json, sys
device = sys.argv[1]
runtimes = [r for r in json.load(sys.stdin)['runtimes']
            if r['platform'] == 'iOS' and r['isAvailable'] and any(t['name'] == device for t in r['supportedDeviceTypes'])]
print(max(runtimes, key=lambda r: [int(p) for p in r['version'].split('.')])['identifier'] if runtimes else '')
" "$device")
[[ -n $runtime ]] || { echo "No iOS runtime supports \"$device\"" >&2; exit 1; }
udid=$(xcrun simctl create "LightEditor UITest $device" "$device" "$runtime")
recorder=""
cleanup() {
    [[ -n $recorder ]] && kill -INT $recorder 2>/dev/null && wait $recorder 2>/dev/null || true
    xcrun simctl shutdown $udid >/dev/null 2>&1 || true
    xcrun simctl delete $udid >/dev/null 2>&1 || true
}
trap cleanup EXIT

if (( build )); then
    echo "Building for testing…"
    xcodegen generate --quiet
    # Check xcodebuild's own status: after `| grep … || true`, $pipestatus is true's,
    # so a failed build used to fall through to testing the previous build.
    if ! xcodebuild build-for-testing -scheme LightEditorUITests -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath $derived -quiet > build/ui-build.log 2>&1; then
        grep -E "error:" build/ui-build.log | grep -v DVTProvisioningProfileManager | sort -u | head -20
        echo "Build failed (build/ui-build.log)" >&2
        exit 1
    fi
fi

xcrun simctl boot $udid
xcrun simctl bootstatus $udid >/dev/null
xcrun simctl io $udid recordVideo --codec h264 --force $dir/tour.mp4 >/dev/null 2>&1 &
recorder=$!
sleep 1

echo "Touring on $device…"
set +e
TEST_RUNNER_UITEST_LIBRARY=$library \
TEST_RUNNER_UITEST_OUTPUT=$out \
xcodebuild test-without-building -scheme LightEditorUITests -derivedDataPath $derived \
    -destination "id=$udid" -only-testing:LightEditorUITests/FeatureTourTests \
    -collect-test-diagnostics never -resultBundlePath $out/tour.xcresult -quiet > $out/last.log 2>&1
rc=$?
set -e
kill -INT $recorder 2>/dev/null; wait $recorder 2>/dev/null || true
recorder=""

# Each failed assertion's message, from the result bundle.
xcrun xcresulttool get test-results tests --path $out/tour.xcresult 2>/dev/null | python3 -c "
import json, sys
def walk(node):
    if node.get('nodeType') == 'Failure Message': print('  ' + node.get('name', ''))
    for child in node.get('children', []): walk(child)
try:
    for root in json.load(sys.stdin).get('testNodes', []): walk(root)
except Exception: pass
" || true
echo "Screenshots: ${dir#$root/}/tour/   Video: ${dir#$root/}/tour.mp4   Log: build/ui-tour/last.log"
echo "Tour $([[ $rc -eq 0 ]] && echo passed || echo FAILED)"
exit $rc
