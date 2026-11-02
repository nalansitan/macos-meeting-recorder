#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/scripts/build-aec.sh"
mkdir -p "$ROOT/build/module-cache"
for TEST in SoftwareAECSmoke SoftwareAECIntegrationSmoke AudioSinkSmoke; do
  xcrun swiftc -O -swift-version 5 -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
    "$ROOT/Sources/AudioSink.swift" "$ROOT/Sources/SoftwareEchoCanceller.swift" \
    "$ROOT/tests/$TEST.swift" -o "$ROOT/build/$TEST"
  "$ROOT/build/$TEST"
done
