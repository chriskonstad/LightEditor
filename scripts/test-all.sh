#!/bin/zsh
# The pre-merge check: everything, with a summary at the end. About 10–15 minutes.
#
#   1. EditorCore unit tests, the real-RAW tests on Fixtures/ (decode, Vision, camera
#      looks, RAW goldens) and the performance budgets
#   2. the same tests under the Thread, Address and Undefined Behavior Sanitizers
#   3. app builds for macOS, the iOS simulator and iOS devices (scripts/build.sh)
#   4. UI tests: screen audits and screenshots in fresh simulators (scripts/test-ui.sh),
#      the behavior, interruption and tour tests under the Main Thread Checker and the
#      Thread Performance Checker (scripts/test-checkers.sh), and the Mac UI tests
#
#   scripts/test-all.sh            all of it
#   scripts/test-all.sh --no-ui    skip the UI tests (no simulators)
#   scripts/test-all.sh --ui-all   UI tests on every device size, not just the quick pair
#
# Logs are in build/test-all/. See docs/TESTING.md.
set -uo pipefail
cd "$(dirname "$0")/.."
ui=1 ui_args=()
for arg in "$@"; do
    case $arg in
        --no-ui) ui=0 ;;
        --ui-all) ui_args+=(--all) ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "Unknown option $arg" >&2; exit 2 ;;
    esac
done
mkdir -p build/test-all
started=$(date +%s)
results=()
failed=0

stage() {
    local name=$1; shift
    local log=build/test-all/${name// /-}.log
    local t0=$(date +%s)
    echo "▶ $name"
    "$@" > $log 2>&1
    local rc=$?
    local dt=$(( $(date +%s) - t0 ))
    if (( rc == 0 )); then
        results+=("PASS  $(printf '%4d' $dt) s  $name")
    else
        results+=("FAIL  $(printf '%4d' $dt) s  $name   ($log)")
        failed=1
        tail -40 $log | sed 's/^/    /'
    fi
}

stage "unit and RAW" env EDITORCORE_RAW_FIXTURES=$PWD/Fixtures scripts/test-fast.sh --models
# Alone, after the rest: in the parallel run above the AI-model and RAW tests share the
# GPU, which slowed a 5 ms preview frame to 500 ms and failed its budget.
stage "performance budgets" env EDITORCORE_RAW_FIXTURES=$PWD/Fixtures EDITORCORE_PERF_BUDGETS=1 scripts/test-fast.sh --filter PerformanceBudget
stage "sanitizers" scripts/test-sanitizers.sh
stage "builds" scripts/build.sh
(( ui )) && stage "UI audits" scripts/test-ui.sh $ui_args
(( ui )) && stage "thread checkers" scripts/test-checkers.sh --no-build
if (( ui )); then
    if automationmodetool 2>&1 | grep -q "requires user authentication"; then
        results+=("SKIP          Mac UI tests   (allow UI automation once: sudo automationmodetool enable-automationmode-without-authentication)")
    else
        stage "Mac UI tests" scripts/test-mac-ui.sh
    fi
fi

echo
printf '%s\n' $results
grep -h "^BUDGET " build/test-all/performance*.log 2>/dev/null | sed 's/^/      /'
echo "Total $(( $(date +%s) - started )) s"
exit $failed
