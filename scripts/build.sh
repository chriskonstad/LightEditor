#!/bin/zsh
# Regenerates the Xcode project and builds the app for iOS (device and simulator) and macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -scheme LightEditor -destination 'platform=macOS' -derivedDataPath build/DerivedData build -quiet
xcodebuild -scheme LightEditor -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData build -quiet
# Device builds need a signing team; this only checks that the code compiles.
xcodebuild -scheme LightEditor -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData build -quiet CODE_SIGNING_ALLOWED=NO
echo "Build OK"
