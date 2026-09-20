#!/bin/sh
# Archives Desk for the App Store and uploads it to App Store Connect, from where
# TestFlight picks it up. Signing is automatic: Xcode's signed-in account creates
# the Apple Distribution certificate and the profiles on first run.
#
#   tools/testflight.sh            archive, export, upload
#   tools/testflight.sh archive    archive only, to build/Desk.xcarchive
#
# The build number is managed by App Store Connect (manageAppVersionAndBuildNumber
# in ExportOptions.plist), so a re-run never collides with the last upload.
set -eu
cd "$(dirname "$0")/.."

ARCHIVE=build/Desk.xcarchive
xcodegen generate >/dev/null

xcodebuild archive \
  -project Desk.xcodeproj \
  -scheme Desk \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  | grep -E "error:|warning: .*(sign|provision)|\*\* ARCHIVE" || true

test -d "$ARCHIVE" || { echo "no archive produced"; exit 1; }
[ "${1:-}" = "archive" ] && exit 0

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist tools/ExportOptions.plist \
  -exportPath build/export \
  -allowProvisioningUpdates \
  | grep -E "error:|Upload|EXPORT|uploaded|Package Summary" || true
