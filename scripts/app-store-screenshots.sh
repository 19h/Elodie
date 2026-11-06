#!/bin/zsh
# Renders the App Store listing's screenshots from fixture data, so nothing private can be in
# them. Mac screenshots have to be 16:10 with no transparency, and this checks both.
set -euo pipefail

root="${0:A:h:h}"
app="$root/build/Elodie/Build/Products/Debug/Elodie.app"
output="$root/docs/app-store/screenshots"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$output"
find "$output" -name '*.jpg' -delete

index=0
for name in timeline search-expanded slice-range jump-to-date timeline-break-hover; do
  (( index += 1 ))
  shot="$scratch/$name.png"
  open -n "$app" --args --scenario "$name" --window 1440x900 --out "$shot"
  for _ in {1..2400}; do
    [[ -f "$shot" || -f "$shot.error" ]] && break
    sleep 0.25
  done
  if [[ ! -f "$shot" ]]; then
    print -u2 "$name failed: $(cat "$shot.error" 2>/dev/null)"
    exit 1
  fi
  sleep 1
  final="$output/$index-$name.jpg"
  sips -s format jpeg -s formatOptions 92 "$shot" --out "$final" >/dev/null
  size=$(sips -g pixelWidth -g pixelHeight "$final" | awk '/pixel/ {print $2}' | tr '\n' 'x')
  if [[ "$size" != "2880x1800x" ]]; then
    print -u2 "$name came out as $size, which the App Store won't take"
    exit 1
  fi
  print "$final"
done
