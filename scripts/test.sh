#!/bin/zsh
# Runs the EditorCore tests on the Mac.
#
#   scripts/test.sh            unit tests
#   scripts/test.sh --raw      ...plus the real-RAW tests on Fixtures/ (decode, Vision,
#                              camera looks against the camera's JPEG, performance)
#   scripts/test.sh --ios      ...and the unit tests in an iOS simulator
#
# EDITORCORE_RAW_FIXTURES points the real-RAW tests at another folder of ARW/RAF/DNG files.
set -euo pipefail
cd "$(dirname "$0")/.."
for arg in "$@"; do
    [[ "$arg" == "--raw" ]] && export EDITORCORE_RAW_FIXTURES=${EDITORCORE_RAW_FIXTURES:-$PWD/Fixtures}
done
swift test --package-path Packages/EditorCore
for arg in "$@"; do
    if [[ "$arg" == "--ios" ]]; then
        destination=${IOS_DESTINATION:-'platform=iOS Simulator,name=iPhone 18 Pro'}
        (cd Packages/EditorCore && xcodebuild test -scheme EditorCore -destination "$destination" -derivedDataPath ../../build/PackageTests -quiet)
    fi
done
