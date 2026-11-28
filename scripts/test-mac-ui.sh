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
#   scripts/test-mac-ui.sh --only MacOpenFromPhotosTests   one class (or Class/method)
#
# The tests take over the mouse and keyboard while they run. macOS asks for an
# administrator's password to allow UI automation unless it's been allowed once:
#   sudo automationmodetool enable-automationmode-without-authentication
# Output: build/mac-ui/ (screenshots, audit.txt, checker reports, the result bundle).
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD

perf=1 record=0 build=1 only=""
while (( $# )); do
    case $1 in
        --no-perf) perf=0 ;;
        --record) record=1 ;;
        --no-build) build=0 ;;
        --only) shift; only=$1 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
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
rm -rf $out && mkdir -p $out
# The sample library each test's copy is made from (MacUITest.template).
rm -rf /private/tmp/LightEditorUITests && mkdir -p /private/tmp/LightEditorUITests/template
cp -c Fixtures/DSC04921.ARW Fixtures/DSCF2030.raf /private/tmp/LightEditorUITests/template/

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
[[ -n $only ]] && filter=(-only-testing:"LightEditorMacUITests/$only")
since=$(date "+%Y-%m-%d %H:%M:%S")
echo "Testing the Mac app (it takes over the mouse and keyboard)…"
set +e
# The runner's sandbox can't read the repo, so the audit baseline goes in by value.
baseline=$(cat MacUITests/audit-baseline.txt 2>/dev/null || true)
MAC_UITEST_CHECKERS=1 MAC_UITEST_RECORD=$record MAC_UITEST_BASELINE=$baseline \
TEST_RUNNER_MAC_UITEST_CHECKERS=1 TEST_RUNNER_MAC_UITEST_RECORD=$record TEST_RUNNER_MAC_UITEST_BASELINE=$baseline \
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
# Screenshots and the audit report come out as attachments (the runner can't write files).
xcrun xcresulttool export attachments --path $out/mac-ui.xcresult --output-path $out/attachments >/dev/null 2>&1 || true
if [[ -f $out/attachments/manifest.json ]]; then
    mkdir -p $out/screens
    python3 - "$out" <<'PY'
import json, os, shutil, sys
out = sys.argv[1]
for test in json.load(open(f"{out}/attachments/manifest.json")):
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName", "")
        src = f"{out}/attachments/{a['exportedFileName']}"
        base = name.rsplit("_", 2)[0] if "_" in name else name
        if base.startswith("audit"):
            shutil.copy(src, f"{out}/{base.split('.')[0]}.txt")
        elif src.endswith(".png"):
            shutil.copy(src, f"{out}/screens/{base.split('.')[0]}.png")
PY
fi
[[ -f $out/audit.txt ]] && echo "  Audit: $(head -1 $out/audit.txt)"
if (( record )) && [[ -f $out/audit-findings.txt ]]; then
    { echo "# Known Mac accessibility audit findings (MacEditorTests.testEveryTabAudits)."
      echo "# One per line: screen | kind | element. Fix the layout and delete the line; never add one to silence a regression."
      cat $out/audit-findings.txt; } > MacUITests/audit-baseline.txt
    echo "  Recorded $(grep -vc '^#' MacUITests/audit-baseline.txt) known findings in MacUITests/audit-baseline.txt"
fi

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

all=$(reports "$since")
echo "$all" > $out/checker-reports.txt
# "[Internal]" reports are waits inside Apple's frameworks (ImageIO waiting on its
# own threads, AppKit's run loop): listed, but only reports in our code fail.
internal=$(grep -c "\[Internal\]" <<< "$all" || true)
found=$(grep -v "\[Internal\]" <<< "$all" | grep . || true)
(( internal > 0 )) && echo "  $internal checker reports inside Apple's frameworks (build/mac-ui/checker-reports.txt), not failing"
if [[ -n $found ]]; then
    echo "Checker reports (build/mac-ui/checker-reports.txt; run the app from Xcode with the checkers on for details):"
    sed -E 's/^.*\[(com\.apple\.[^]]*)\].*$/\1/' <<< "$found" | sort | uniq -c | sort -rn
fi
if (( rc != 0 )) || [[ -n $found ]]; then
    echo "Mac UI tests FAILED (build/mac-ui/test.log)"
    exit 1
fi
echo "Mac UI tests passed"
