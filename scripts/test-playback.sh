#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build/module-cache"
FFMPEG="$(command -v ffmpeg || true)"
if [ -z "$FFMPEG" ]; then FFMPEG=/opt/homebrew/bin/ffmpeg; fi
"$FFMPEG" -nostdin -v error -y -f lavfi -i anullsrc=r=16000:cl=mono -t 3 -c:a alac "$ROOT/build/playback-silent.m4a"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT/Sources/SpeakerIdentity.swift" "$ROOT/Sources/RecordingPlayback.swift" "$ROOT/tests/PlaybackSmoke.swift" -o "$ROOT/build/playback-test"
"$ROOT/build/playback-test" "$ROOT/build/playback-silent.m4a"
