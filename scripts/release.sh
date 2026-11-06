#!/bin/zsh
# Builds a Developer ID signed release in build/release.
#
# With no options it makes a disk image, and uploads nothing. That image isn't notarized, so it
# won't open on other Macs. Notarizing sends the build to Apple, so that only happens if you ask:
#
#   scripts/release.sh --distribute                  # build/release/Elodie.zip, using Xcode's sign-in
#   scripts/release.sh --notarize <keychain-profile> # a notarized disk image, using a profile
#                                                    # from `xcrun notarytool store-credentials`
set -euo pipefail

root="${0:A:h:h}"
output="$root/build/release"
archive="$output/Elodie.xcarchive"
notary_profile=""
distribute=false
if [[ "${1:-}" == "--notarize" ]]; then
  notary_profile="${2:?usage: release.sh --notarize <keychain-profile>}"
elif [[ "${1:-}" == "--distribute" ]]; then
  distribute=true
fi

cd "$root"
"$root/scripts/check-privacy.sh"
xcodegen generate --quiet

rm -rf "$output"
mkdir -p "$output"

xcodebuild -project Elodie.xcodeproj -scheme Elodie -configuration Release \
  -derivedDataPath "$root/build/ElodieData-Release" -archivePath "$archive" \
  ENABLE_HARDENED_RUNTIME=YES archive -quiet

app="$archive/Products/Applications/Elodie.app"
codesign --verify --deep --strict --verbose=1 "$app"
"$root/scripts/check-bundle.sh" "$app" direct

if [[ "$distribute" == true ]]; then
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$output/upload" \
    -exportOptionsPlist "$root/scripts/DeveloperIDExportOptions.plist" -allowProvisioningUpdates -quiet
  rm -rf "$output/upload"

  # Apple usually answers within minutes. Until then this fails, saying it's still processing.
  notarized="$output/notarized"
  for attempt in {1..90}; do
    xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$notarized" >/dev/null 2>&1 && break
    (( attempt == 90 )) && { print -u2 "Apple hasn't finished notarizing after 30 minutes."; exit 1; }
    sleep 20
  done

  xcrun stapler validate "$notarized/Elodie.app"
  syspolicy_check distribution "$notarized/Elodie.app"
  "$root/scripts/check-bundle.sh" "$notarized/Elodie.app" direct
  ditto -c -k --keepParent "$notarized/Elodie.app" "$output/Elodie.zip"
  rm -rf "$notarized"
  print "Built $output/Elodie.zip"
  exit 0
fi

staging="$output/staging"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
dmg="$output/Elodie.dmg"
hdiutil create -quiet -volname Elodie -srcfolder "$staging" -ov -format UDZO "$dmg"
rm -rf "$staging"
codesign --sign "Developer ID Application" --timestamp "$dmg"

if [[ -n "$notary_profile" ]]; then
  xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
else
  print "Not notarized. Gatekeeper will warn on other Macs until it is."
fi
print "Built $dmg"
