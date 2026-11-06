#!/bin/zsh
# Builds a Developer ID signed release and a disk image in build/release.
#
# It doesn't upload anything. Notarizing sends the build to Apple, so that only happens if
# you pass --notarize, with a profile stored by `xcrun notarytool store-credentials`:
#
#   scripts/release.sh --notarize <keychain-profile>
set -euo pipefail

root="${0:A:h:h}"
output="$root/build/release"
archive="$output/Elodie.xcarchive"
notary_profile=""
if [[ "${1:-}" == "--notarize" ]]; then
  notary_profile="${2:?usage: release.sh --notarize <keychain-profile>}"
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
