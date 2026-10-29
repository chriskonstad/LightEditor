#!/bin/zsh
# Runs the EditorCore tests on the Mac, and on an iOS simulator with --ios.
# Set EDITORCORE_RAW_FIXTURES to a folder of real ARW/RAF/DNG files to include the
# RAW decode and performance tests.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Packages/EditorCore
if [[ "${1:-}" == "--ios" ]]; then
    destination=${IOS_DESTINATION:-'platform=iOS Simulator,name=iPhone 18 Pro'}
    (cd Packages/EditorCore && xcodebuild test -scheme EditorCore -destination "$destination" -derivedDataPath ../../build/PackageTests -quiet)
fi
