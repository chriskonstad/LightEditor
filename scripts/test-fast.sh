#!/bin/zsh
# The inner loop: EditorCore's unit tests on the Mac, with only what failed printed.
# About 5 s with a warm build (a minute or two cold). Extra arguments go to `swift test`:
#
#   scripts/test-fast.sh                          everything that needs no fixtures
#   scripts/test-fast.sh --filter RenderGolden    one suite (a regex on test names)
#   scripts/test-fast.sh --models                 also the real LaMa/diffusion runs (~40 s
#                                                 more; skipped by default when Models/ exists)
#   EDITORCORE_RECORD=1 scripts/test-fast.sh --filter "RenderGolden|RecipeCompat"
#                                                 re-record goldens after an intended change
#
# The full log is in build/test-fast.log. See docs/TESTING.md for which test covers what.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
log=build/test-fast.log
started=$(date +%s)

args=() skip=(--skip "InpaintTests|DiffusionInpaintTests")
for arg in "$@"; do
    if [[ $arg == --models ]]; then skip=(); else args+=("$arg"); fi
done

swift test --package-path Packages/EditorCore $skip $args > $log 2>&1
rc=$?
elapsed=$(( $(date +%s) - started ))

# Swift Testing and XCTest summaries.
summary=$(grep -E "^(✔|✘) Test run with|Executed [0-9]+ tests" $log | tail -2 | tr '\n' ' ')
if (( rc == 0 )); then
    echo "PASS in ${elapsed} s: ${summary:-no tests matched}"
    grep -E "^BUDGET " $log | sort -u || true
    exit 0
fi

echo "FAIL in ${elapsed} s (full log: $log)"
echo
# Compiler errors, failed expectations with their details, and failed XCTest cases.
grep -E "error:|^✘ Test .*(recorded an issue|failed)|^↳ |XCTAssert|XCTFail|Test Case .* failed" $log \
    | grep -v -E "^↳ (Testing Library Version|Target Platform)" \
    | grep -v -E "^✘ (Suite|Test run)" \
    | awk '!seen[$0]++' | head -80
grep -E "^BUDGET " $log | sort -u || true
echo
echo "${summary}"
exit $rc
