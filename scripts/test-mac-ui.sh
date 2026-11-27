#!/bin/zsh
# The Mac app's UI tests (MacUITests/): editing with the mouse and keyboard, every
# tab with Apple's accessibility audit, the watermark, hiding and quitting, and
# launch / open / slider-drag performance. The app runs with the Main Thread Checker
# and the Thread Performance Checker loaded, and any report fails the run.
#
#   scripts/test-mac-ui.sh                 everything
#   scripts/test-mac-ui.sh --no-perf       skip MacPerformanceTests (about 2 minutes)
#   scripts/test-mac-ui.sh --record        accept this run's audit findings into MacUITests/audit-baseline.txt
#   scripts/test-mac-ui.sh --no-build      reuse the last build
#
# The tests take over the mouse and keyboard while they run. macOS asks for an
# administrator's password to allow UI automation unless it's been allowed once:
#   sudo automationmodetool enable-automationmode-without-authentication
# Output: build/mac-ui/ (screenshots, audit.txt, checker reports, the result bundle).
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD

perf=1 record=0 build=1
while (( $# )); do
    case $1 in
        --no-perf) perf=0 ;;
        --record) record=1 ;;
        --no-build) build=0 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "Unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

if automationmodetool 2>&1 | grep -q "requires user authentication"; then
    echo "macOS needs an administrator to allow UI automation once. Run:" >&2
    echo "  sudo automationmodetool enable-automationmode-without-authentication" >&2
    echo "(undo with: sudo automationmodetool disable-automationmode-without-authentication)" >&2
    exit 1
fi

derived=build/MacUITests
out=$root/build/mac-ui
rm -rf $out && mkdir -p $out /private/tmp/LightEditorUITests

if (( build )); then
    echo "Building for testing…"
    xcodegen generate --quiet
    set +e
    xcodebuild build-for-testing -scheme LightEditorMacUITests -destination 'platform=macOS' -derivedDataPath $derived > $out/build.log 2>&1
    rc=$?
    set -e
    (( rc == 0 )) || { grep -E "error:" $out/build.log | head -20; echo "Build failed ($out/build.log)" >&2; exit 1; }
fi

# Checker reports from the app in this Mac's log since a moment. macOS redacts the
# messages as <private>, but each keeps its subsystem tag, which is what's matched.
# (/usr/bin/log: in zsh, plain `log` is a builtin.)
reports() {
    /usr/bin/log show --style compact --start "$1" \
        --predicate 'process == "LightEditor" AND (subsystem == "com.apple.MainThreadChecker" OR subsystem == "com.apple.runtime-issues")' 2>/dev/null \
        | grep -E "com\.apple\.MainThreadChecker|com\.apple\.runtime-issues" || true
}

# First prove both checkers report, with the app breaking each rule once on purpose.
echo "Checking the checkers…"
app=$derived/Build/Products/Debug/LightEditor.app
canary=/private/tmp/LightEditorUITests/canary
mkdir -p $canary && cp -c Fixtures/DSCF2030.raf $canary/
since=$(date "+%Y-%m-%d %H:%M:%S")
DYLD_INSERT_LIBRARIES="$(xcode-select -p)/usr/lib/libMainThreadChecker.dylib:/usr/lib/libRPAC.dylib" MTC_LOG_REPORTS_TO_OS_LOG=1 \
    $app/Contents/MacOS/LightEditor -FixtureLibrary $canary -ResetState YES -DebugCheckerViolation YES -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
pid=$!
sleep 8
kill $pid 2>/dev/null; wait $pid 2>/dev/null || true
found=$(reports "$since")
if ! grep -q "MainThreadChecker" <<< "$found" || ! grep -q "Hang Risk" <<< "$found"; then
    echo "The checkers didn't report the deliberate violations, so a clean run would mean nothing." >&2
    exit 1
fi
echo "  both checkers report"

filter=()
(( perf )) || filter=(-skip-testing:LightEditorMacUITests/MacPerformanceTests)
since=$(date "+%Y-%m-%d %H:%M:%S")
echo "Testing the Mac app (it takes over the mouse and keyboard)…"
set +e
MAC_UITEST_OUTPUT=$out MAC_UITEST_CHECKERS=1 MAC_UITEST_RECORD=$record \
TEST_RUNNER_MAC_UITEST_OUTPUT=$out TEST_RUNNER_MAC_UITEST_CHECKERS=1 TEST_RUNNER_MAC_UITEST_RECORD=$record \
xcodebuild test-without-building -scheme LightEditorMacUITests -destination 'platform=macOS' -derivedDataPath $derived \
    $filter -resultBundlePath $out/mac-ui.xcresult -collect-test-diagnostics never > $out/test.log 2>&1
rc=$?
set -e
rm -rf /private/tmp/LightEditorUITests

grep -E "error:" $out/test.log | grep -v DVTProvisioning | sed 's/^.*: error: /error: /' | sort -u | head -20 || true
xcrun xcresulttool get test-results summary --path $out/mac-ui.xcresult 2>/dev/null | python3 -c "
import json, sys
s = json.load(sys.stdin)
print(f\"  {s.get('passedTests', 0)} passed, {s.get('failedTests', 0)} failed, {s.get('skippedTests', 0)} skipped\")" || true
[[ -f $out/audit.txt ]] && echo "  Audit: $(head -1 $out/audit.txt)"

if (( perf )); then
    # The measured averages, from the result bundle.
    xcrun xcresulttool get test-results metrics --path $out/mac-ui.xcresult 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for test in data:
    for run in test.get('testRuns', []):
        for metric in run.get('metrics', []):
            values = metric.get('measurements', [])
            if values:
                mean = sum(values) / len(values)
                print(f\"  PERF {test.get('testIdentifier', '?').split('/')[-1]} · {metric.get('displayName')}: {mean:.3f} {metric.get('unitOfMeasurement', '')}\")
" || echo "  (no performance metrics in the result bundle)"
fi

found=$(reports "$since")
echo "$found" > $out/checker-reports.txt
if [[ -n $found ]]; then
    echo "Checker reports (build/mac-ui/checker-reports.txt; run the app from Xcode with the checkers on for details):"
    sed -E 's/^.*\[(com\.apple\.[^]]*)\].*$/\1/' <<< "$found" | sort | uniq -c | sort -rn
fi
if (( rc != 0 )) || [[ -n $found ]]; then
    echo "Mac UI tests FAILED (build/mac-ui/test.log)"
    exit 1
fi
echo "Mac UI tests passed"
