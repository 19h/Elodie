#!/bin/zsh
# Checks a built app the way App Store review would, as far as that's possible from here.
#   scripts/check-bundle.sh <path to Elodie.app> <direct|appstore>
set -uo pipefail

app="${1:?usage: check-bundle.sh <app> <direct|appstore>}"
edition="${2:?usage: check-bundle.sh <app> <direct|appstore>}"
binary="$app/Contents/MacOS/Elodie"
failures=0
fail() { print -u2 "  FAILED: $*"; (( failures += 1 )); }
entitlements() { codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -p - 2>/dev/null; }

[[ -x "$binary" ]] || { print -u2 "No app at $app"; exit 1; }
imports=$(xcrun nm -um "$binary")

# In every edition: no updater, no test code, and no way onto the network.
if [[ -e "$app/Contents/Frameworks/Sparkle.framework" ]] || print -r -- "$imports" | grep -qi sparkle; then
  fail "an updater is in the bundle"
fi
[[ -n $(find "$app" -name '*.xpc' -o -name 'Autoupdate' 2>/dev/null) ]] && fail "update helpers are in the bundle"
for name in SyntheticScreen FakeCore FixtureVault LiveSpikes Scenarios InputSelfTest; do
  strings -a "$binary" | grep -q "$name" && fail "test code named $name is in the binary"
done
print -r -- "$imports" | grep -qE '_OBJC_CLASS_\$_NS(URLSession|URLConnection|Stream)|_nw_|_CFSocket|_CFStreamCreate|_getaddrinfo' \
  && fail "the binary imports networking calls"
entitlements "$app" | grep -q 'security.network' && fail "an entitlement allows network access"
[[ -f "$app/Contents/Resources/PrivacyInfo.xcprivacy" ]] || fail "no privacy manifest"
for key in NSScreenCaptureUsageDescription NSMicrophoneUsageDescription NSCalendarsFullAccessUsageDescription ITSAppUsesNonExemptEncryption; do
  plutil -extract "$key" raw "$app/Contents/Info.plist" >/dev/null 2>&1 || fail "Info.plist has no $key"
done

# App Review only accepts public APIs. Every imported symbol has to be in the public SDK.
sdk=$(xcrun --sdk macosx --show-sdk-path)
public=$(mktemp)
find "$sdk/System/Library/Frameworks" "$sdk/usr/lib" -name '*.tbd' -print0 | xargs -0 cat 2>/dev/null \
  | tr -d "',[]" | tr ' ' '\n' | grep -E '^_|^\$' | LC_ALL=C sort -u > "$public"
private=$(print -r -- "$imports" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[_$]/){print $i; break}}' | LC_ALL=C sort -u \
  | LC_ALL=C comm -23 - "$public" | grep -vE '^_OBJC_(CLASS|METACLASS|EHTYPE|IVAR)_')
rm -f "$public"
[[ -n "$private" ]] && { print -u2 -r -- "$private"; fail "imports symbols outside the public SDK"; }
otool -L "$binary" | tail -n +2 | awk '{print $1}' | grep -E 'PrivateFrameworks' && fail "links a private framework"

if [[ "$edition" == "appstore" ]]; then
  entitlements "$app" | grep -q 'app-sandbox" => true' || fail "the app isn't sandboxed"
  entitlements "$app" | grep -q 'temporary-exception' && fail "it uses a temporary sandbox exception"
  entitlements "$app" | grep -q 'get-task-allow' && fail "it's a debug build"
  for extension in "$app"/Contents/PlugIns/*.appex; do
    entitlements "$extension" | grep -q 'app-sandbox" => true' || fail "${extension:t} isn't sandboxed"
  done
  print -r -- "$imports" | grep -qE '_AXUIElement|_AXIsProcessTrusted' && fail "Accessibility code is in the App Store build"
  print -r -- "$imports" | grep -q '_CGEventTapCreate' && fail "an event tap is in the App Store build"
  [[ -e "$app/Contents/Library/LaunchAgents" ]] && fail "a launch agent is in the App Store build"
  [[ $(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist") == *.dev ]] && fail "it has the development bundle ID"
fi

if (( failures > 0 )); then
  print -u2 "$failures bundle checks failed for $edition"
  exit 1
fi
print "Bundle checks passed for the $edition edition: $(print -r -- "$imports" | wc -l | tr -d ' ') imported symbols, all public."
