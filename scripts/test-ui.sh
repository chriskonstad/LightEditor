#!/bin/zsh
# UI tests: walks the app's main screens in iOS simulators, at the default and the
# largest Dynamic Type size (and landscape on iPad), audits each screen for clipped
# text, touch targets under 44 pt and off-screen layout, and saves screenshots.
#
#   scripts/test-ui.sh                   quick: iPhone SE (smallest screen) and iPad mini
#   scripts/test-ui.sh --all             ...plus iPhone 18 Pro Max and iPad Pro 13-inch
#   scripts/test-ui.sh --devices "iPhone 17e,iPad Air 11-inch (M4)"
#   scripts/test-ui.sh --only testScreensAtDefaultTextSize     one test method
#   scripts/test-ui.sh --keep            keep the simulators for a faster next run
#   scripts/test-ui.sh --no-build        reuse the last build
#   scripts/test-ui.sh --report-only     write the audit without failing on it
#   scripts/test-ui.sh --record-baseline accept this run's findings into UITests/audit-baseline.txt
#
# Screenshots and audit.txt land in build/ui-screenshots/<device>/<orientation>-<size>/.
# The run uses its own simulators ("LightEditor UITest …"), never ones already booted,
# and the app reads a copy of Fixtures/ as a folder library, never a Photos library.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD

devices=("iPhone SE (3rd generation)" "iPad mini (A17 Pro)")
keep=0 build=1 only="" strict=1 record=0
while (( $# )); do
    case $1 in
        --all) devices=("iPhone SE (3rd generation)" "iPad mini (A17 Pro)" "iPhone 18 Pro Max" "iPad Pro 13-inch (M5)") ;;
        --devices) shift; devices=("${(@s:,:)1}") ;;
        --only) shift; only=$1 ;;
        --keep) keep=1 ;;
        --no-build) build=0 ;;
        --report-only) strict=0 ;;
        --record-baseline) strict=0 record=1 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "Unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

started=$(date +%s)
derived=build/UITests
results=build/ui-results
mkdir -p $results

# A worktree has no Models/ (not in git); borrow the main checkout's so the project builds.
if [[ ! -e Models ]]; then
    main=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
    if [[ -d $main/Models ]]; then ln -s "$main/Models" Models; echo "Linked Models/ from $main"; fi
fi

# The library: clones (copy-on-write, so instant) of a RAW and a JPEG from Fixtures/.
library=$root/build/ui-test-library
rm -rf $library && mkdir -p $library
cp -c Fixtures/DSC04921.ARW Fixtures/DSCF2763.jpg $library/

# Our own simulators, created on the newest runtime that supports each device.
typeset -A udids
created=()
cleanup() {
    (( keep )) && return
    for udid in $created; do
        xcrun simctl shutdown $udid >/dev/null 2>&1 || true
        xcrun simctl delete $udid >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

for device in $devices; do
    name="LightEditor UITest $device"
    udid=$(xcrun simctl list devices -j | python3 -c "
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)['devices'].items():
    for d in devices:
        if d['name'] == name and d['isAvailable']: print(d['udid']); sys.exit()
" "$name")
    if [[ -z $udid ]]; then
        runtime=$(xcrun simctl list runtimes -j | python3 -c "
import json, sys
device = sys.argv[1]
runtimes = [r for r in json.load(sys.stdin)['runtimes']
            if r['platform'] == 'iOS' and r['isAvailable'] and any(t['name'] == device for t in r['supportedDeviceTypes'])]
print(max(runtimes, key=lambda r: [int(p) for p in r['version'].split('.')])['identifier'] if runtimes else '')
" "$device")
        [[ -n $runtime ]] || { echo "No iOS runtime supports \"$device\"" >&2; exit 1; }
        udid=$(xcrun simctl create "$name" "$device" "$runtime")
    fi
    (( keep )) || created+=$udid
    udids[$device]=$udid
done

if (( build )); then
    echo "Building for testing…"
    xcodegen generate --quiet
    xcodebuild build-for-testing -scheme LightEditorUITests -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath $derived -quiet 2>&1 | grep -v -e "^$" -e DVTProvisioningProfileManager || true
    [[ ${pipestatus[1]} -eq 0 ]] || { echo "Build failed" >&2; exit 1; }
fi

destinations=()
for device in $devices; do destinations+=(-destination "id=${udids[$device]}"); done
# FeatureTourTests is a demo for scripts/ui-tour.sh, not an audit.
filter=(-skip-testing:LightEditorUITests/FeatureTourTests)
[[ -n $only ]] && filter=(-only-testing:"LightEditorUITests/ScreenAuditTests/$only")

bundle=$results/$(date +%Y%m%d-%H%M%S).xcresult
rm -rf build/ui-screenshots
echo "Testing on: ${(j:, :)devices}"
set +e
TEST_RUNNER_UITEST_LIBRARY=$library \
TEST_RUNNER_UITEST_OUTPUT=$root/build/ui-screenshots \
TEST_RUNNER_UITEST_STRICT=$strict \
xcodebuild test-without-building -scheme LightEditorUITests -derivedDataPath $derived \
    $destinations $filter -maximum-concurrent-test-simulator-destinations ${#devices} \
    -collect-test-diagnostics never -resultBundlePath $bundle -quiet > $results/last.log 2>&1
rc=$?
set -e

# What failed, without the noise.
grep -E "error:|\[FAIL\]|TEST EXECUTE (SUCCEEDED|FAILED)|Testing failed" $results/last.log \
    | grep -v DVTProvisioningProfileManager | sed 's/^.*: error: /error: /' | sort -u | head -60 || true
echo

if (( record )); then
    # Replace the baseline's lines for each device and configuration that ran.
    python3 - UITests/audit-baseline.txt build/ui-screenshots/*/*/baseline.txt(N) <<'PY'
import sys
target, runs = sys.argv[1], sys.argv[2:]
try:
    lines = open(target).read().splitlines()
except FileNotFoundError:
    lines = []
header = [l for l in lines if l.startswith("#")]
entries = {l for l in lines if l and not l.startswith("#")}
for run in runs:
    run_lines = open(run).read().splitlines()
    prefix = run_lines[0].removeprefix("# prefix: ")
    current = {l for l in run_lines[1:] if l}
    entries = {e for e in entries if not e.startswith(prefix)} | current
open(target, "w").write("\n".join(header + sorted(entries)) + "\n")
print(f"Recorded {len(entries)} known findings in {target}")
PY
fi

for report in build/ui-screenshots/*/*/audit.txt(N); do
    printf "%-60s %s\n" "${report#build/ui-screenshots/}" "$(sed -n 3p $report)"
done
echo
echo "Screenshots: build/ui-screenshots/   Log: $results/last.log   Results: $bundle"
echo "UI tests $([[ $rc -eq 0 ]] && echo passed || echo FAILED) in $(( $(date +%s) - started )) s"
exit $rc
