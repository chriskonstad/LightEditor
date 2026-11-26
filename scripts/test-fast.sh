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
# A run whose log stops growing for TEST_STALL_SECONDS (default 300) is a hang: it's
# stopped, and the tests that started but never finished are listed.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
log=build/test-fast.log
started=$(date +%s)

args=() skip=(--skip "InpaintTests|DiffusionInpaintTests")
for arg in "$@"; do
    if [[ $arg == --models ]]; then skip=(); else args+=("$arg"); fi
done

stall=${TEST_STALL_SECONDS:-300}
swift test --package-path Packages/EditorCore $skip $args > $log 2>&1 &
runner=$!
stalled=0 last_size=-1 quiet=0
while kill -0 $runner 2>/dev/null; do
    sleep 5
    size=$(stat -f %z $log 2>/dev/null || echo 0)
    if (( size == last_size )); then (( quiet += 5 )); else quiet=0 last_size=$size; fi
    if (( quiet >= stall )); then
        stalled=1
        pkill -P $runner 2>/dev/null; kill $runner 2>/dev/null
        pkill -f "swiftpm-testing-helper.*EditorCoreTests" 2>/dev/null
        break
    fi
done
wait $runner 2>/dev/null
rc=$?
elapsed=$(( $(date +%s) - started ))

if (( stalled )); then
    echo "HUNG: no test output for ${stall} s; stopped after ${elapsed} s (full log: $log)"
    echo "Started but never finished:"
    python3 - $log <<'PY'
import re, sys
log = open(sys.argv[1], errors="ignore").read()
started = re.findall(r"◇ Test (\S+?\(.*?\)) started", log)
finished = set(re.findall(r"Test (\S+?\(.*?\)) (?:passed|failed|skipped|recorded)", log))
for name in dict.fromkeys(started):
    if name not in finished:
        print("  " + name)
PY
    echo "A test awaiting something that never resumes holds everything queued behind it"
    echo "(e.g. RenderGate.fullSize). Run the listed tests alone with --filter to compare."
    exit 124
fi

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
