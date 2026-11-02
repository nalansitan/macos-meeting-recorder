#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT" --scratch-path "$ROOT/build/spm" -c debug --product MeetingRecorder -j 4
BIN="$(swift build --package-path "$ROOT" --scratch-path "$ROOT/build/spm" -c debug --show-bin-path)"
DEPS="$ROOT/build/spm/checkouts/FluidAudio/Sources"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
  -I "$BIN" -I "$DEPS/FastClusterWrapper/include" -I "$DEPS/MachTaskSelfWrapper/include" \
  "$BIN/FluidAudio.o" "$BIN/FastClusterWrapper.o" "$BIN/MachTaskSelfWrapper.o" -lc++ \
  "$ROOT/Sources/SpeakerIdentity.swift" "$ROOT/Sources/SpeakerRuntime.swift" \
  "$ROOT/tests/SpeakerReplay.swift" -o "$ROOT/build/speaker-replay"
"$ROOT/build/speaker-replay" "$@"
