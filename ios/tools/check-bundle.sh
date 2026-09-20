#!/bin/bash
# Run this on an .xcarchive (or a .app) BEFORE uploading to App Store Connect.
# Apple refuses any symbolic link inside the bundle (ITMS-90332), and the
# rejection arrives by email an hour later, after everyone has gone to bed.
set -euo pipefail

TARGET="${1:?usage: check-bundle.sh <path to .xcarchive or .app>}"
APP="$TARGET"
[ -d "$TARGET/Products/Applications" ] && APP="$(find "$TARGET/Products/Applications" -maxdepth 1 -name '*.app' | head -1)"
[ -d "$APP" ] || { echo "no app bundle at $TARGET" >&2; exit 1; }

links="$(find "$APP" -type l || true)"
if [ -n "$links" ]; then
    echo "SYMLINKS IN THE BUNDLE — Apple will reject this upload:" >&2
    echo "$links" >&2
    exit 1
fi

echo "no symlinks in $(basename "$APP")"
for d in VisionModel NarratorModel; do
    [ -d "$APP/$d" ] && echo "$d: $(find "$APP/$d" -type f | wc -l | tr -d ' ') files, $(du -sh "$APP/$d" | cut -f1)"
done
