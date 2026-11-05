#!/bin/zsh
# Spike 6. Runs the crash, power-cut, and full-disk tests in a scratch directory
# and removes everything afterward.
#   scripts/torture.sh <scratch-dir> [kill-iterations] [power-iterations] [enospc-iterations]
set -euo pipefail

scratch="${1:?usage: torture.sh <scratch-dir> [kill] [power] [enospc]}"
kill_iterations="${2:-1000}"
power_iterations="${3:-300}"
enospc_iterations="${4:-100}"
root="${0:A:h:h}"

mkdir -p "$scratch"
scratch="${scratch:A}"
image="$scratch/enospc.sparseimage"
mount_point="$scratch/enospc-volume"

cleanup() {
  [[ -d "$mount_point" ]] && hdiutil detach "$mount_point" -quiet -force 2>/dev/null || true
  rm -rf "$scratch/kill" "$scratch/power" "$image" "$mount_point"
}
trap cleanup EXIT

cd "$root/core"
cargo build --release -q -p torture
torture="$root/core/target/release/torture"

# If the checker can't detect damage, nothing below means anything.
"$torture" self-test "$scratch/self-test"
rm -rf "$scratch/self-test"

failed=0
"$torture" kill "$scratch/kill" "$kill_iterations" || failed=1
"$torture" power "$scratch/power" "$power_iterations" || failed=1

hdiutil create -quiet -size 64m -type SPARSE -fs APFS -volname RemindTorture "$image"
mkdir -p "$mount_point"
hdiutil attach -quiet -nobrowse -mountpoint "$mount_point" "$image"
"$torture" enospc "$mount_point" "$enospc_iterations" || failed=1

exit $failed
