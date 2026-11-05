#!/bin/bash
# Xcode Cloud only (build machine, never shipped): put the on-device model folders where the Xcode resource phase
# expects them, like tools/stage-models.sh does on our own Macs. The weights are too big for git, so Xcode Cloud
# downloads the built-in ("balanced") vision model and checks every file against vision-model-manifest.json
# (size + sha256). Real folders and real files only: a symlinked VisionModel is rejected by Apple (ITMS-90332).
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

if find "$IOS/VisionModel" "$IOS/NarratorModel" -type l | grep -q .; then
    echo "error: a symlink in the model folders, do not archive this tree" >&2
    exit 1
fi
du -sh "$IOS/VisionModel" "$IOS/NarratorModel" "$IOS/LICENSE"
