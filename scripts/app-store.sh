#!/bin/zsh
# Archives the App Store edition, and checks it in build/app-store.
#
# It doesn't upload anything. With --export, it also signs the archive for distribution and
# makes the package to upload, which needs an Xcode signed in to the developer account:
#
#   scripts/app-store.sh --export
#
# The upload itself is left to you, in Xcode's Organizer or Transporter.
set -euo pipefail

root="${0:A:h:h}"
output="$root/build/app-store"
archive="$output/Elodie.xcarchive"

cd "$root"
"$root/scripts/check-privacy.sh"
xcodegen generate --quiet

rm -rf "$output"
mkdir -p "$output"

xcodebuild -project Elodie.xcodeproj -scheme "Elodie App Store" -configuration AppStore \
  -derivedDataPath "$root/build/DerivedAppStore" -archivePath "$archive" archive -quiet

app="$archive/Products/Applications/Elodie.app"
codesign --verify --deep --strict --verbose=1 "$app"
"$root/scripts/check-bundle.sh" "$app" appstore

if [[ "${1:-}" == "--export" ]]; then
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$output/export" \
    -exportOptionsPlist "$root/scripts/AppStoreExportOptions.plist" -allowProvisioningUpdates
  print "Ready to upload: $output/export"
else
  print "Archived $archive"
fi
