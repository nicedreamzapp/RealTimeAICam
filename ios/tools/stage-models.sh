#!/bin/bash
# Put the on-device model folders where the Xcode resource phase expects them.
# They are too big for git, so they live in the model tree and are copied in
# before a build.
#
# COPY, never symlink. These are folder references: Xcode copies the reference
# as it finds it, so a symlinked VisionModel ships as a symlink and Apple
# rejects the upload with ITMS-90332 — that killed build 31 of 1.3.0 on
# 2026-09-20 and cost a re-upload at three in the morning.
set -euo pipefail

SRC="${1:-$HOME/a11y-work/ios601}"
DST="$(cd "$(dirname "$0")/.." && pwd)"

for item in VisionModel NarratorModel LICENSE; do
    [ -e "$SRC/$item" ] || { echo "missing: $SRC/$item" >&2; exit 1; }
    rm -rf "$DST/$item"
    cp -RL "$SRC/$item" "$DST/$item"   # -L resolves every link on the way in
done

if find "$DST/VisionModel" "$DST/NarratorModel" -type l 2>/dev/null | grep -q .; then
    echo "a symlink survived the copy — do not archive this tree" >&2
    exit 1
fi

echo "staged from $SRC:"
du -sh "$DST/VisionModel" "$DST/NarratorModel" "$DST/LICENSE"
