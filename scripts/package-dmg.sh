#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid version' >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Build on Apple Silicon' >&2; exit 1; }
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { echo 'Commit source changes before packaging' >&2; exit 1; }
OUT="$ROOT/build/releases/v$VERSION"
DMG="macos-meeting-recorder-$VERSION-macos-arm64.dmg"
[[ ! -e "$OUT/$DMG" ]] || { echo "Already exists: $OUT/$DMG" >&2; exit 1; }
bash "$ROOT/scripts/build.sh"
APP="$ROOT/build/会议录音.app"
codesign --verify --deep --strict "$APP"
mkdir -p "$OUT"
STAGE=$(mktemp -d "$ROOT/build/dmg-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/会议录音.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/install.md" "$STAGE/安装与使用说明.txt"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/"
hdiutil create -volname "会议录音 $VERSION" -srcfolder "$STAGE" -format UDZO -fs HFS+ "$OUT/$DMG"
hdiutil verify "$OUT/$DMG"
(cd "$OUT" && shasum -a 256 "$DMG" > SHA256SUMS)
cp "$ROOT/docs/install.md" "$OUT/INSTALL.md"
cp "$ROOT/docs/releases/v$VERSION.md" "$OUT/RELEASE-NOTES.md"
printf 'Version: %s\nCommit: %s\nArchitecture: arm64\nSigning: ad-hoc; not notarized\n' \
 "$VERSION" "$(git -C "$ROOT" rev-parse HEAD)" > "$OUT/BUILD-INFO.txt"
echo "$OUT"
