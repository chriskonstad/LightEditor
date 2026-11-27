#!/bin/zsh
# EditorCore's tests under the sanitizers: Thread Sanitizer (data races), then
# Address and Undefined Behavior Sanitizers (memory errors, overflow, misaligned
# access). Swift 6's checks catch most races at compile time, but not inside
# `@unchecked Sendable` types, locks and callbacks, which this catches at run time.
#
#   scripts/test-sanitizers.sh            both, without the AI-model tests (~1 min)
#   scripts/test-sanitizers.sh --models   with the LaMa, diffusion and depth tests too (+2 min)
#
# Fails on any sanitizer report, even if every test passes.
set -uo pipefail
cd "$(dirname "$0")/.."
skip=(--skip "InpaintTests|DiffusionInpaintTests|DepthModelTests")
[[ ${1:-} == --models ]] && skip=()
mkdir -p build/sanitizers
failed=0
for sanitizers in "thread" "address undefined"; do
    name=${sanitizers// /+}
    log=build/sanitizers/$name.log
    flags=(); for s in ${=sanitizers}; do flags+=(--sanitize=$s); done
    echo "▶ $sanitizers"
    swift test --package-path Packages/EditorCore $flags $skip > $log 2>&1
    rc=$?
    reports=$(grep -c -E "WARNING: ThreadSanitizer|ERROR: AddressSanitizer|runtime error:" $log)
    summary=$(grep -E "Test run with .* (passed|failed)" $log | tail -1 | sed 's/^.*Test run/Test run/')
    if (( rc != 0 || reports > 0 )); then
        echo "  FAILED: $reports reports, $summary ($log)"
        grep -E -A12 "WARNING: ThreadSanitizer|ERROR: AddressSanitizer|runtime error:" $log | head -60
        failed=1
    else
        echo "  clean: $summary"
    fi
done
exit $failed
