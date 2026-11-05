#!/bin/zsh
# Runs each scenario in the app and collects what it drew in build/scenarios.
# None of these take focus or need any permission. An app can always capture its own
# windows, and these capture nothing else.
set -u
cd "$(dirname "$0")/.."
# Set REMIND_APP to use a build from somewhere else.
APP="${REMIND_APP:-$PWD/build/Derived/Build/Products/Debug/Remind.app}"
OUT="$PWD/build/scenarios"
mkdir -p "$OUT"

failures=0

run() {
    local name=$1 file=$2
    rm -f "${OUT:?}/${file:?}" "${OUT:?}/${file:?}.error"
    open -n "$APP" --args --scenario "$name" --out "$OUT/$file"
    for _ in {1..1400}; do
        [ -f "$OUT/$file" ] || [ -f "$OUT/$file.error" ] && break
        sleep 0.25
    done
    if [ -f "$OUT/$file.error" ]; then
        echo "FAILED $name: $(cat "$OUT/$file.error")"
        failures=$((failures + 1))
    elif [ ! -f "$OUT/$file" ]; then
        echo "FAILED $name: nothing was written"
        failures=$((failures + 1))
    else
        echo "ok $name"
    fi
}

scenes=(
    onboarding-welcome onboarding-how onboarding-permissions onboarding-ready recovery
    settings-general settings-screen settings-audio settings-meetings settings-storage settings-shortcuts
    timeline coach-marks search-compact search-expanded search-starred search-apps jump-to-date status-menu overflow-menu
    slice-hover slice-selected slice-range slice-confirm timeline-zoom timeline-break timeline-break-hover timeline-break-crossed timeline-break-range forget-confirm
    meeting-prompt notice-card transcripts transcript recap ask
)
for name in $scenes; do
    run "$name" "$name.png"
done

# Controls have to stay readable over anything: 4.5:1 is the gate.
for backdrop in white black noisy saturated; do
    rm -f "${OUT:?}/contrast-${backdrop:?}.png.txt"
    run "contrast-$backdrop" "contrast-$backdrop.png"
    # The measurement is written just after the image.
    for _ in {1..40}; do
        [ -f "$OUT/contrast-$backdrop.png.txt" ] && break
        sleep 0.25
    done
    if [ ! -f "$OUT/contrast-$backdrop.png.txt" ]; then
        echo "FAILED contrast-$backdrop: nothing was measured"
        failures=$((failures + 1))
        continue
    fi
    result=$(cat "$OUT/contrast-$backdrop.png.txt")
    echo "   $result"
    ratio=${${result#* }%%:*}
    if (( ratio < 4.5 )); then
        echo "FAILED contrast-$backdrop: below 4.5:1"
        failures=$((failures + 1))
    fi
done

echo "$failures failed. Images are in build/scenarios."
[ "$failures" -eq 0 ]
