#!/bin/bash
# Xcode Cloud only (build machine, never shipped): put the on-device model folders where the Xcode resource phase
# expects them, like tools/stage-models.sh does on our own Macs. The weights are too big for git, so Xcode Cloud
# downloads the built-in ("balanced") vision model and the llama.cpp xcframework and checks every file against vision-model-manifest.json
# (size + sha256). Real folders and real files only: a symlinked VisionModel is rejected by Apple (ITMS-90332).
# Xcode Cloud blocks Swift package plugins/macros (mlx-swift's CudaBuild) until they are trusted; trust them here.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IOS="$(cd "$HERE/.." && pwd)"
BASE="${RTCAM_VISION_MODEL_URL:-https://ineedhemp.com/models/rtcam/lfm3-omni-2b-iq2xs-v1/}"
MANIFEST="$HERE/vision-model-manifest.json"

rm -rf "$IOS/VisionModel" "$IOS/NarratorModel" "$IOS/LICENSE"
mkdir -p "$IOS/VisionModel" "$IOS/NarratorModel"     # NarratorModel ships empty since 1.3.6
cp "$IOS/../LICENSE" "$IOS/LICENSE"
cp "$MANIFEST" "$IOS/VisionModel/manifest.json"

python3 - "$MANIFEST" > "$HERE/.files" <<'PY'
import json, sys
for f in json.load(open(sys.argv[1]))["files"]:
    print(f["name"], f["size"], f["sha256"])
PY

while read -r name size sha; do
    echo "downloading $name ($size bytes)"
    curl -fsSL --retry 4 --retry-delay 5 -o "$IOS/VisionModel/$name" "${BASE%/}/$name"
    got_size=$(stat -f %z "$IOS/VisionModel/$name")
    got_sha=$(shasum -a 256 "$IOS/VisionModel/$name" | cut -d' ' -f1)
    if [ "$got_size" != "$size" ] || [ "$got_sha" != "$sha" ]; then
        echo "error: $name does not match the manifest (size $got_size, sha $got_sha)" >&2
        exit 1
    fi
done < "$HERE/.files"
rm -f "$HERE/.files"

# llama.cpp b11954 xcframework, the exact build 1.3.6 links against (also too big for git, see NARRATOR-LLAMA.md).
LLAMA_URL="${RTCAM_LLAMA_URL:-https://ineedhemp.com/models/rtcam/llama-b11954/llama-b11954.xcframework.zip}"
LLAMA_SIZE=116584749
LLAMA_SHA=771c0cfe4f441e7f3dac83d608042f7c7b6533cf3c2ae19c8e5bb3e494a8111d
LLAMA_ZIP="$(mktemp -d)/llama.xcframework.zip"
echo "downloading llama.xcframework ($LLAMA_SIZE bytes)"
curl -fsSL --retry 4 --retry-delay 5 -o "$LLAMA_ZIP" "$LLAMA_URL"
got_size=$(stat -f %z "$LLAMA_ZIP")
got_sha=$(shasum -a 256 "$LLAMA_ZIP" | cut -d' ' -f1)
if [ "$got_size" != "$LLAMA_SIZE" ] || [ "$got_sha" != "$LLAMA_SHA" ]; then
    echo "error: llama.xcframework zip does not match (size $got_size, sha $got_sha)" >&2
    exit 1
fi
rm -rf "$IOS/Frameworks/llama.xcframework"
mkdir -p "$IOS/Frameworks"
unzip -q "$LLAMA_ZIP" -d "$IOS/Frameworks"   # keeps the macOS slice's framework symlinks; only VisionModel must be link-free
rm -f "$LLAMA_ZIP"
[ -f "$IOS/Frameworks/llama.xcframework/Info.plist" ] || { echo "error: llama.xcframework missing after unzip" >&2; exit 1; }

if find "$IOS/VisionModel" "$IOS/NarratorModel" -type l | grep -q .; then
    echo "error: a symlink in the model folders, do not archive this tree" >&2
    exit 1
fi
du -sh "$IOS/VisionModel" "$IOS/NarratorModel" "$IOS/LICENSE" "$IOS/Frameworks/llama.xcframework"
