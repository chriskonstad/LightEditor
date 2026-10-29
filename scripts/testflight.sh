#!/bin/zsh
# Builds LightEditor for iOS and uploads it to TestFlight.
#
#   scripts/testflight.sh                  archive, upload, and send to the external
#                                          "Friends" group (waits for processing)
#   scripts/testflight.sh --internal-only  archive and upload for internal testers only
#                                          (marked TestFlight-internal, so it can't go to the App Store)
#   scripts/testflight.sh --no-upload      archive and export an .ipa only
#
# Internal testers ("Me") get every build automatically. The external group needs
# Beta App Review, which scripts/testflight-external.py submits for.
#
# Needs:
# - Config/Signing.local.xcconfig with DEVELOPMENT_TEAM (see Config/Base.xcconfig).
# - An App Store Connect app record for com.chriskonstad.lighteditor.
# - Upload credentials, either:
#   - Config/AppStoreConnect.env (git-ignored) with ASC_KEY_ID, ASC_ISSUER_ID and
#     ASC_KEY_PATH pointing at the .p8 API key (best for unattended runs), or
#   - an Apple ID signed in to Xcode › Settings › Accounts.
set -euo pipefail
cd "$(dirname "$0")/.."

upload=true
external=true
case "${1:-}" in
    --no-upload) upload=false ;;
    --internal-only) external=false ;;
esac

team=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Signing.local.xcconfig 2>/dev/null | tr -d ' ')
[[ -n "$team" ]] || { echo "Set DEVELOPMENT_TEAM in Config/Signing.local.xcconfig"; exit 1; }

auth=()
if [[ -f Config/AppStoreConnect.env ]]; then
    source Config/AppStoreConnect.env
    auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

# Build numbers only need to increase; a timestamp always does.
build=$(date +%y%m%d%H%M)
archive=build/release/LightEditor.xcarchive
export_dir=build/release/export
rm -rf build/release
mkdir -p build/release

[[ -d Models/LaMa.mlpackage ]] || echo "warning: Models/LaMa.mlpackage is missing, so AI removal will be off (run scripts/fetch-models.sh)"

xcodegen generate --quiet
echo "Archiving build $build…"
xcodebuild archive -quiet \
    -scheme LightEditor -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -allowProvisioningUpdates "${auth[@]}" \
    CURRENT_PROJECT_VERSION="$build"

destination=export
$upload && destination=upload
cat > build/release/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$destination</string>
    <key>teamID</key><string>$team</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>testFlightInternalTestingOnly</key><$($external && echo false || echo true)/>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "Exporting ($destination)…"
xcodebuild -exportArchive -quiet \
    -archivePath "$archive" \
    -exportOptionsPlist build/release/ExportOptions.plist \
    -exportPath "$export_dir" \
    -allowProvisioningUpdates "${auth[@]}"

if $upload; then
    echo "Uploaded build $build. It appears in TestFlight after processing (usually 5–15 minutes)."
    if $external; then
        echo "Sending build $build to external testers once it's processed…"
        scripts/testflight-external.py "$build" "$(git log -5 --format='• %s')"
    fi
else
    echo "Exported to $export_dir"
fi
