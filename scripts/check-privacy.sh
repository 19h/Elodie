#!/bin/zsh
# Checks what Elodie says about privacy against the code, so it can't quietly stop being true.
set -uo pipefail

root="${0:A:h:h}"
failures=0

fail() {
  print -u2 "FAILED: $1"
  failures=$((failures + 1))
}

cd "$root"
sources=(App Widgets Packages/ElodieKit/Sources)
matches() {
  # Generated bindings and the two harnesses that launch local tools aren't app logic.
  grep -rnE "$1" "${sources[@]}" --include='*.swift' \
    --exclude-dir=Generated --exclude=LiveSpikes.swift 2>/dev/null
}

# Only the updater may use the network. Everything else stays on this Mac.
network='URLSession|NWConnection|NWPathMonitor|^import Network|CFSocket|CFStream|WKWebView|URLRequest|NSURLConnection'
found=$(matches "$network")
[[ -n "$found" ]] && { print -u2 "$found"; fail "networking outside Sparkle"; }

found=$(matches '^import Sparkle' | grep -v 'App/Updater.swift')
[[ -n "$found" ]] && { print -u2 "$found"; fail "Sparkle used outside App/Updater.swift"; }

# Ask runs on the device. The SDK also offers a cloud model, which must never be used.
found=$(matches 'PrivateCloudCompute')
[[ -n "$found" ]] && { print -u2 "$found"; fail "the cloud model is used"; }

# No analytics or crash reporting.
found=$(matches '^import (Sentry|Segment|FirebaseAnalytics|Mixpanel|Amplitude|LaunchDarkly|TelemetryDeck)')
[[ -n "$found" ]] && { print -u2 "$found"; fail "telemetry framework imported"; }

# Nothing from Rewind ships with Elodie.
found=$(grep -rliE 'rewind\.ai|memoryvault|limitless\.ai|What if you had perfect memory' App Widgets Packages/ElodieKit/Sources core/crates 2>/dev/null)
[[ -n "$found" ]] && { print -u2 "$found"; fail "text copied from the reference app"; }
if git ls-files | grep -qE '(^|/)ui-assets/|\.i64$|REWIND_(SPEC|UI)\.md'; then
  fail "reference material is in the repository"
fi

# The Rust library can't reach the network if it doesn't link the calls for it.
lib="core/target/aarch64-apple-darwin/debug/libelodie_ffi.a"
if [[ -f "$lib" ]]; then
  # Rust's standard library defines its own networking, which is only linked in if used,
  # so what matters is whether anything of ours asks for it.
  found=$(nm -u "$lib" 2>/dev/null | grep -E '^_(getaddrinfo|connect|sendto|recvfrom)$' | sort -u)
  own=$(nm -A -u "$lib" 2>/dev/null | grep -E '_(getaddrinfo|connect)$' | grep -vE '(std-|rustc_std)' | head -5)
  [[ -n "$own" ]] && { print -u2 "$own"; fail "the Rust core links network calls"; }
  : "$found"
else
  fail "the Rust library hasn't been built, so it wasn't checked"
fi
if grep -qE '^(reqwest|hyper|ureq|tokio|surf|isahc)' core/Cargo.toml; then
  fail "the Rust core depends on a network library"
fi
tree=$(cd core && cargo tree -p elodie-ffi --prefix none --edges normal 2>/dev/null)
if print -r -- "$tree" | grep -qE '^(reqwest|hyper|ureq|tokio-rustls|isahc|native-tls|rustls) '; then
  fail "a Rust dependency brings in networking"
fi

if (( failures > 0 )); then
  print -u2 "$failures privacy checks failed"
  exit 1
fi
print "Privacy checks passed: networking only in the updater, no cloud model, no telemetry, nothing from the reference app."
