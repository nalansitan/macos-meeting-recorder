#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build/module-cache"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT/Sources/RecordingLibrary.swift" "$ROOT/tests/RecordingLibrarySmoke.swift" -o "$ROOT/build/library-test"
"$ROOT/build/library-test"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT/Sources/SpeakerIdentity.swift" "$ROOT/Sources/SpeakerRuntime.swift" "$ROOT/Sources/SoftwareEchoCanceller.swift" "$ROOT/Sources/Recorder.swift" "$ROOT/Sources/AudioSink.swift" "$ROOT/Sources/LiveCaptions.swift" \
  "$ROOT/Sources/SpeechModelAssets.swift" "$ROOT/Sources/RecordingStorage.swift" "$ROOT/Sources/RecordingLibrary.swift" \
  "$ROOT/tests/RecorderLifecycleSmoke.swift" -o "$ROOT/build/lifecycle-test"
"$ROOT/build/lifecycle-test"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT/Sources/SpeakerIdentity.swift" "$ROOT/Sources/AudioSink.swift" "$ROOT/Sources/SoftwareEchoCanceller.swift" "$ROOT/Sources/LiveCaptions.swift" \
  "$ROOT/tests/CaptionShutdownSmoke.swift" -o "$ROOT/build/caption-shutdown-test"
"$ROOT/build/caption-shutdown-test"
