#!/bin/bash
# Build only. Launching the independent app requests microphone access and runs
# a ~35 second physical speaker/microphone experiment; do so only when ready.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/AECProbe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/module-cache"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT/tests/AECProbe.swift" -o "$APP/Contents/MacOS/AECProbe"
say -v Tingting -r 180 -o "$APP/Contents/Resources/reference.aiff" \
  '现在开始回声消除测试。我们正在讨论项目交付和客户需求。请确认下周三之前完成测试，并在会议结束后保存录音和字幕。'
/usr/bin/python3 - "$APP" <<'PY'
import plistlib
import sys
from pathlib import Path
app = Path(sys.argv[1])
if (app / 'Contents/Resources/reference.aiff').stat().st_size <= 4096:
    raise SystemExit('测试语音生成失败：文件为空。请检查本机 Tingting 语音是否可用。')
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'local.infra.meeting-recorder.aec-probe',
    'CFBundleName': '会议录音回声验证', 'CFBundleExecutable': 'AECProbe',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '15.0',
    'NSMicrophoneUsageDescription': '验证电脑外放的回声消除效果；录音仅保存到本机临时目录，不上传。',
}))
PY
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
