#!/bin/zsh
# The app under the Main Thread Checker and the Thread Performance Checker, in a
# throwaway iPhone simulator: UI calls off the main thread, and the main thread
# waiting on lower-priority work (a hang risk), while the UI tests drive it.
#
#   scripts/test-checkers.sh              EditorBehaviorTests, InterruptionTests, FeatureTourTests
#   scripts/test-checkers.sh --no-build   reuse the last UI test build
#
# Both checkers report to the system log (see UITestConfig.makeApp); this script
# reads the app's reports from the simulator's log afterwards and fails on any.
# First it launches the app with -DebugCheckerViolation, which breaks both rules
# once on purpose, and checks both reports arrive: a clean run then means clean,
# not that the checkers never loaded.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD

build=1 device="iPhone 18 Pro"
while (( $# )); do
    case $1 in
        --no-build) build=0 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

derived=build/UITests
out=$root/build/checkers
rm -rf $out && mkdir -p $out
library=$out/library
mkdir -p $library && cp -c Fixtures/DSC04921.ARW Fixtures/DSCF2763.jpg $library/

if [[ ! -e Models ]]; then
    main=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
    [[ -d $main/Models ]] && ln -s "$main/Models" Models
fi

if (( build )); then
    echo "Building for testing…"
    xcodegen generate --quiet
    set +e
    xcodebuild build-for-testing -scheme LightEditorUITests -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath $derived -quiet > $out/build.log 2>&1
    rc=$?
    set -e
    (( rc == 0 )) || { grep -E "error:" $out/build.log | head -20; echo "Build failed ($out/build.log)" >&2; exit 1; }
fi

runtime=$(xcrun simctl list runtimes -j | python3 -c "
import json, sys
device = sys.argv[1]
runtimes = [r for r in json.load(sys.stdin)['runtimes']
            if r['platform'] == 'iOS' and r['isAvailable'] and any(t['name'] == device for t in r['supportedDeviceTypes'])]
print(max(runtimes, key=lambda r: [int(p) for p in r['version'].split('.')])['identifier'] if runtimes else '')
" "$device")
[[ -n $runtime ]] || { echo "No iOS runtime supports \"$device\"" >&2; exit 1; }
udid=$(xcrun simctl create "LightEditor UITest checkers" "$device" "$runtime")
trap 'xcrun simctl shutdown $udid >/dev/null 2>&1; xcrun simctl delete $udid >/dev/null 2>&1' EXIT
xcrun simctl boot $udid
xcrun simctl bootstatus $udid >/dev/null

# The app's checker reports since a moment, one per line.
reports() {
    xcrun simctl spawn $udid log show --style compact --start "$1" \
        --predicate 'process == "LightEditor" AND (subsystem == "com.apple.MainThreadChecker" OR subsystem == "com.apple.runtime-issues")' 2>/dev/null \
        | grep -E "Main Thread Checker:|Hang Risk|runtime-issues" || true
}

echo "Checking the checkers…"
app=$(find $derived/Build/Products/Debug-iphonesimulator -maxdepth 1 -name "LightEditor.app" | head -1)
xcrun simctl install $udid "$app"
since=$(date "+%Y-%m-%d %H:%M:%S")
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=/usr/lib/libMainThreadChecker.dylib:/usr/lib/libRPAC.dylib \
SIMCTL_CHILD_MTC_LOG_REPORTS_TO_OS_LOG=1 \
xcrun simctl launch $udid com.chriskonstad.lighteditor -FixtureLibrary $library -ResetState YES -DebugCheckerViolation YES >/dev/null
sleep 6
xcrun simctl terminate $udid com.chriskonstad.lighteditor >/dev/null 2>&1 || true
canary=$(reports "$since")
if ! grep -q "Main Thread Checker:" <<< "$canary" || ! grep -q "Hang Risk" <<< "$canary"; then
    echo "The checkers didn't report the deliberate violations, so a clean run would mean nothing:" >&2
    echo "$canary" >&2
    exit 1
fi
echo "  both checkers report"

echo "Testing on $device with the checkers…"
since=$(date "+%Y-%m-%d %H:%M:%S")
set +e
TEST_RUNNER_UITEST_LIBRARY=$library \
TEST_RUNNER_UITEST_OUTPUT=$out \
TEST_RUNNER_UITEST_CHECKERS=1 \
xcodebuild test-without-building -scheme LightEditorUITests -derivedDataPath $derived -destination "id=$udid" \
    -only-testing:LightEditorUITests/EditorBehaviorTests -only-testing:LightEditorUITests/InterruptionTests \
    -only-testing:LightEditorUITests/FeatureTourTests \
    -collect-test-diagnostics never -resultBundlePath $out/checkers.xcresult -quiet > $out/test.log 2>&1
rc=$?
set -e
grep -E "error:|\[FAIL\]" $out/test.log | sed 's/^.*: error: /error: /' | sort -u | head -20 || true
xcrun xcresulttool get test-results summary --path $out/checkers.xcresult 2>/dev/null | python3 -c "
import json, sys
s = json.load(sys.stdin)
print(f\"  {s.get('passedTests', 0)} passed, {s.get('failedTests', 0)} failed, {s.get('skippedTests', 0)} skipped\")" || true

found=$(reports "$since")
echo "$found" > $out/reports.txt
if [[ -n $found ]]; then
    echo "Checker reports (build/checkers/reports.txt):"
    # Each report's first line, once.
    grep -E "Main Thread Checker:|Hang Risk" <<< "$found" | sed -E 's/^.*(Main Thread Checker:|\[com\.apple\.runtime-issues:Hang Risk\])/\1/' | sort | uniq -c | sort -rn | head -20
fi
if (( rc != 0 )) || [[ -n $found ]]; then
    echo "Checkers FAILED"
    exit 1
fi
echo "Checkers passed: no UI calls off the main thread and no hang risks"
