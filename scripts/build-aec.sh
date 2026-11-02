#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/aec-deps"
SOURCE="$DEPS/webrtc-audio-processing-2.1"
TOOLS="$DEPS/tools/bin"
mkdir -p "$DEPS"
if [[ ! -d "$SOURCE" ]]; then
  curl -fL --retry 2 https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz -o "$DEPS/webrtc-audio-processing-2.1.tar.xz"
  echo 'ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe  '"$DEPS/webrtc-audio-processing-2.1.tar.xz" | shasum -a 256 -c -
  tar -xf "$DEPS/webrtc-audio-processing-2.1.tar.xz" -C "$DEPS"
fi
if [[ ! -x "$TOOLS/meson" ]]; then
  # Use a fixed build-tool interpreter; macOS system Python may be too old for Meson.
  uv venv --python 3.12 --clear "$DEPS/tools"
  uv pip install --python "$TOOLS/python" meson==1.12.1 ninja==1.13.2
fi
export PATH="$TOOLS:$PATH"
export MACOSX_DEPLOYMENT_TARGET=15.0
if [[ ! -f "$DEPS/compiled/build.ninja" ]]; then
  meson setup "$DEPS/compiled" "$SOURCE" --buildtype=release --default-library=static \
    -Dcpp_args=-mmacosx-version-min=15.0 -Dc_args=-mmacosx-version-min=15.0
fi
meson compile -C "$DEPS/compiled" -j 6
# Bundle all static dependencies so the installed app needs no Homebrew libraries.
LIBS=()
while IFS= read -r library; do LIBS+=("$library"); done < <(find "$DEPS/compiled" -name '*.a' -type f | sort)
xcrun libtool -static -o "$DEPS/libMeetingAEC-deps.a" "${LIBS[@]}" 2>"$DEPS/libtool.log"
xcrun clang++ -std=c++17 -O2 -dynamiclib -mmacosx-version-min=15.0 -fvisibility=hidden \
  -DWEBRTC_MAC -DWEBRTC_POSIX -DWEBRTC_LIBRARY_IMPL \
  -I"$SOURCE/webrtc" -I"$SOURCE/subprojects/abseil-cpp-20240722.0" \
  "$ROOT/Native/MeetingAEC.cpp" "$DEPS/libMeetingAEC-deps.a" \
  -framework Foundation -framework CoreFoundation \
  -install_name @rpath/libMeetingAEC.dylib -o "$ROOT/build/libMeetingAEC.dylib"
codesign --force --sign - "$ROOT/build/libMeetingAEC.dylib"
mkdir -p "$ROOT/build/aec-licenses"
cp "$SOURCE/COPYING" "$ROOT/build/aec-licenses/WebRTC-COPYING"
cp "$SOURCE/webrtc/LICENSE" "$ROOT/build/aec-licenses/WebRTC-LICENSE"
cp "$SOURCE/webrtc/PATENTS" "$ROOT/build/aec-licenses/WebRTC-PATENTS"
cp "$SOURCE/subprojects/abseil-cpp-20240722.0/LICENSE" "$ROOT/build/aec-licenses/Abseil-LICENSE"

for COMPONENT in third_party/rnnoise/COPYING third_party/pffft/LICENSE modules/third_party/fft/LICENSE common_audio/third_party/spl_sqrt_floor/LICENSE common_audio/third_party/ooura/LICENSE; do
  NAME="${COMPONENT//\//-}"
  cp "$SOURCE/webrtc/$COMPONENT" "$ROOT/build/aec-licenses/$NAME"
done
