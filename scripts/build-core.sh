#!/bin/zsh
# Builds the Rust core and packages it for Swift.
#   scripts/build-core.sh [debug|release]
set -euo pipefail

profile="${1:-debug}"
root="${0:A:h:h}"
target="aarch64-apple-darwin"
framework="$root/Packages/ElodieKit/Frameworks/ElodieCoreFFI.xcframework"
glue="$root/Packages/ElodieKit/Sources/CoreABI/Generated"
scratch="$root/build/core-bindings"

cd "$root/core"

cargo_flags=(-p elodie-ffi --target "$target")
[[ "$profile" == "release" ]] && cargo_flags+=(--release)
MACOSX_DEPLOYMENT_TARGET=26.0 cargo build "${cargo_flags[@]}"

lib_dir="$root/core/target/$target/$profile"

# Skip packaging when the library hasn't changed, so Xcode doesn't rebuild the
# Swift that depends on it.
stamp="$scratch/stamp"
if [[ -f "$stamp" && -d "$framework" && -f "$glue/elodie_ffi.swift" \
      && "$stamp" -nt "$lib_dir/libelodie_ffi.a" ]]; then
  exit 0
fi

rm -rf "$scratch" "$framework"
mkdir -p "$scratch/headers" "$glue"

cargo run -q -p uniffi-bindgen -- generate \
  --library "$lib_dir/libelodie_ffi.dylib" \
  --language swift --out-dir "$scratch/generated"

cp "$scratch/generated/elodie_ffiFFI.h" "$scratch/headers/"
cp "$scratch/generated/elodie_ffiFFI.modulemap" "$scratch/headers/module.modulemap"
cp "$scratch/generated/elodie_ffi.swift" "$glue/elodie_ffi.swift"

mkdir -p "${framework:h}"
xcodebuild -create-xcframework \
  -library "$lib_dir/libelodie_ffi.a" -headers "$scratch/headers" \
  -output "$framework" >/dev/null

touch "$stamp"
