#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/会议录音.app"
bash "$ROOT/scripts/build-aec.sh"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/module-cache"
ICONSET="$ROOT/build/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ROOT/Resources/AppIcon.png" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  RETINA_SIZE=$((SIZE * 2))
  sips -z "$RETINA_SIZE" "$RETINA_SIZE" "$ROOT/Resources/AppIcon.png" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
swift build --package-path "$ROOT" --scratch-path "$ROOT/build/spm" -c release --product MeetingRecorder -j 4
BIN_DIR="$(swift build --package-path "$ROOT" --scratch-path "$ROOT/build/spm" -c release --show-bin-path)"
cp "$BIN_DIR/MeetingRecorder" "$APP/Contents/MacOS/MeetingRecorder"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/scripts/export.py" "$APP/Contents/Resources/export.py"
cp "$ROOT/Resources/Speaker-Models-NOTICE.txt" "$APP/Contents/Resources/"
install -m 644 "$ROOT/build/spm/checkouts/FluidAudio/LICENSE" "$APP/Contents/Resources/FluidAudio-LICENSE.txt"
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/AEC-Licenses"
cp "$ROOT/build/libMeetingAEC.dylib" "$APP/Contents/Frameworks/"
cp "$ROOT/build/aec-licenses/"* "$APP/Contents/Resources/AEC-Licenses/"
codesign --force --sign - "$APP/Contents/Frameworks/libMeetingAEC.dylib"
codesign --force --sign - "$APP"
echo "$APP"
