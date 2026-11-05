#!/bin/bash
# Builds the money replay from the app's own source files (no copies), against the macOS slice of llama.xcframework.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/../../project 601"
FW="${LLAMA_XCFRAMEWORK:-$HERE/../../Frameworks/llama.xcframework}/macos-arm64_x86_64"
[ -d "$FW" ] || FW="$HOME/rtcam-repo/ios/Frameworks/llama.xcframework/macos-arm64_x86_64"
OUT="${1:-/tmp/money-replay}"
swiftc -O -F "$FW" -framework llama -Xlinker -rpath -Xlinker "$FW" \
  "$APP/LiveCam/LiveMoney.swift" "$APP/LiveCam/LiveBrain.swift" "$APP/LiveCam/LiveVisionEngine.swift" \
  "$HERE/Stubs.swift" "$HERE/main.swift" -o "$OUT"
echo "built $OUT"
