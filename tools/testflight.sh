#!/bin/sh
# Archives Desk for the App Store and uploads it to App Store Connect, from where
# TestFlight picks it up. Signing is automatic: Xcode's signed-in account creates
# the Apple Distribution certificate and the profiles on first run.
#
#   tools/testflight.sh            archive, export, upload
#   tools/testflight.sh archive    archive only, to build/Desk.xcarchive
#   tools/testflight.sh upload     upload the archive already there
#
# The upload needs App Store Connect access. Either sign an Apple ID with access to
# the team into Xcode (Settings > Accounts), or export an App Store Connect API key
# (Users and Access > Integrations > App Store Connect API, role App Manager) and set
#   ASC_KEY_ID=ABC123DEFG ASC_ISSUER_ID=<uuid> ASC_KEY_PATH=~/.private_keys/AuthKey_ABC123DEFG.p8
# The key never enters the repo; it is read from wherever ASC_KEY_PATH points.
#
# The build number is managed by App Store Connect (manageAppVersionAndBuildNumber
# in ExportOptions.plist), so a re-run never collides with the last upload.
set -eu
cd "$(dirname "$0")/.."

AUTH=""
if [ -n "${ASC_KEY_ID:-}" ]; then
  AUTH="-authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID -authenticationKeyPath ${ASC_KEY_PATH:-$HOME/.private_keys/AuthKey_$ASC_KEY_ID.p8}"
fi

ARCHIVE=build/Desk.xcarchive
if [ "${1:-}" = "upload" ] && [ -d "$ARCHIVE" ]; then
  echo "using the archive already in $ARCHIVE"
else
xcodegen generate >/dev/null

# shellcheck disable=SC2086
xcodebuild archive \
  -project Desk.xcodeproj \
  -scheme Desk \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates $AUTH \
  | grep -E "error:|warning: .*(sign|provision)|\*\* ARCHIVE" || true

fi

test -d "$ARCHIVE" || { echo "no archive produced"; exit 1; }
[ "${1:-}" = "archive" ] && exit 0

# shellcheck disable=SC2086
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist tools/ExportOptions.plist \
  -exportPath build/export \
  -allowProvisioningUpdates $AUTH \
  | grep -E "error:|Upload|EXPORT|uploaded|Package Summary" || true
