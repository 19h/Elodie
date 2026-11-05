#!/bin/zsh
# Sends real events through the real overlay. Unlike the scenarios, this takes over the
# screen and keyboard for a few seconds, and anything typed meanwhile lands in it and can
# fail the test, so it asks first.
set -u
cd "$(dirname "$0")/.."
# Set REMIND_APP to use a build from somewhere else.
APP="${REMIND_APP:-$PWD/build/DerivedData/Build/Products/Debug/Remind.app}"
OUT="$PWD/build/scenarios"
mkdir -p "$OUT"

print -n "This takes over your screen and keyboard for a few seconds. Hands off, then press Return: "
read -r

failed=0
for name in overlay-swipe overlay-input; do
    rm -f "${OUT:?}/${name:?}.txt" "${OUT:?}/${name:?}.txt.error"
    open -n "$APP" --args --scenario "$name" --out "$OUT/$name.txt"
    for _ in {1..400}; do
        [ -f "$OUT/$name.txt" ] || [ -f "$OUT/$name.txt.error" ] && break
        sleep 0.25
    done
    echo "== $name"
    cat "$OUT/$name.txt" "$OUT/$name.txt.error" 2>/dev/null
    echo
    grep -q "^FAIL" "$OUT/$name.txt" 2>/dev/null && failed=1
    [ -f "$OUT/$name.txt" ] || failed=1
done
exit $failed
