#!/bin/zsh
# Builds a Release build and installs it on a paired iPhone or iPad over USB or the
# local network. Faster than TestFlight when the device is nearby.
#
#   scripts/install-device.sh            the first connected iPhone
#   scripts/install-device.sh <udid>     a specific device (see `xcrun devicectl list devices`)
set -euo pipefail
cd "$(dirname "$0")/.."

device=${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /connected/ && /iPhone/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')}
[[ -n "$device" ]] || { echo "No connected iPhone found. Pair it in Xcode › Devices, on the same network or by USB."; exit 1; }

xcodegen generate --quiet
xcodebuild -quiet -scheme LightEditor -configuration Release -destination "id=$device" \
    -derivedDataPath build/DeviceDD -allowProvisioningUpdates build
xcrun devicectl device install app --device "$device" build/DeviceDD/Build/Products/Release-iphoneos/LightEditor.app
echo "Installed on $device"
