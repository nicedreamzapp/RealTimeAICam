#!/usr/bin/env python3
"""Write manifest.json for a vision model folder.

Usage: make_manifest.py MODEL_DIR [--version v4-q4all] [--out manifest.json]

Every regular file in MODEL_DIR (top level only, manifest.json itself skipped)
is listed with its byte size and sha256. The app (VisionModelStore.swift)
checks sizes on every launch and hashes once at install time. Upload the
folder plus this manifest to VisionModelStore.baseURL.
"""
import argparse, hashlib, json, os, sys

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(4 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("model_dir")
    ap.add_argument("--version", default=None, help="defaults to the folder name")
    ap.add_argument("--out", default=None, help="defaults to MODEL_DIR/manifest.json")
    a = ap.parse_args()
    d = os.path.abspath(a.model_dir)
    if not os.path.isdir(d):
        sys.exit(f"not a directory: {d}")
    files = []
    for name in sorted(os.listdir(d)):
        p = os.path.join(d, name)
        if name == "manifest.json" or name.startswith(".") or not os.path.isfile(p):
            continue
        files.append({"name": name, "size": os.path.getsize(p), "sha256": sha256(p)})
        print(f"{name:40s} {files[-1]['size']:>12d}  {files[-1]['sha256']}", file=sys.stderr)
    manifest = {"version": a.version or os.path.basename(d), "files": files}
    out = a.out or os.path.join(d, "manifest.json")
    with open(out, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    total = sum(x["size"] for x in files)
    print(f"wrote {out}: {len(files)} files, {total/1e9:.2f} GB", file=sys.stderr)

if __name__ == "__main__":
    main()
