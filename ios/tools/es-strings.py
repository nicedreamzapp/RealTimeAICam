#!/usr/bin/env python3
"""Spanish strings for the iOS app (2026-11-05).

Every user-visible string goes through L("English") in Swift; the Spanish lives in
project 601/Localizable.xcstrings. This tool keeps the two in step.

  es-strings.py keys               every L("...") key in the app, one per line
  es-strings.py missing            keys with no Spanish yet (exit 1 if any)
  es-strings.py merge FILE.json..  add {"English": "Spanish"} pairs to the catalog
  es-strings.py literals           Text/Button/label literals that skip L() (likely English left on screen)
  es-strings.py stale              catalog entries no L() uses any more

Format keys keep their %@ / %d / %ld / %% exactly; the Spanish must use the same ones, in order.
"""
import json
import re
import sys
from pathlib import Path

IOS = Path(__file__).resolve().parent.parent
CATALOG = IOS / "project 601" / "Localizable.xcstrings"
SKIP_DIRS = ("Tests", "UITests", "unused-assets", "tools", ".build")

# L("...") with the first argument a plain string literal (escaped quotes allowed).
L_CALL = re.compile(r'(?<![A-Za-z0-9_.])L\(\s*"((?:[^"\\\n]|\\.)*)"(?:\s*,\s*context:\s*"([^"]*)")?')
SPEC = re.compile(r"%(?:\d+\$)?(?:@|l?l?d|f|\.\d+f|%)")


def swift_files():
    for p in IOS.rglob("*.swift"):
        rel = p.relative_to(IOS).as_posix()
        if any(part.endswith(SKIP_DIRS) or part in SKIP_DIRS for part in p.relative_to(IOS).parts[:-1]):
            continue
        yield p, rel


def unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n == "u" and s[i + 2:i + 3] == "{":
                j = s.index("}", i)
                out.append(chr(int(s[i + 3:j], 16)))
                i = j + 1
                continue
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'", "0": "\0"}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def keys():
    found = {}
    for p, rel in swift_files():
        for n, line in enumerate(p.read_text().splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            for m in L_CALL.finditer(line):
                raw = m.group(1)
                if "\\(" in raw:
                    print(f"WARNING interpolation inside L(): {rel}:{n}", file=sys.stderr)
                key = unescape(raw) + (f" [{m.group(2)}]" if m.group(2) else "")
                found.setdefault(key, f"{rel}:{n}")
    return found


def load():
    if CATALOG.exists():
        return json.loads(CATALOG.read_text())
    return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}


def save(cat):
    cat["strings"] = dict(sorted(cat["strings"].items(), key=lambda kv: kv[0].lower()))
    CATALOG.write_text(json.dumps(cat, ensure_ascii=False, indent=2, separators=(",", " : ")) + "\n")


def spanish(cat, k):
    return cat["strings"].get(k, {}).get("localizations", {}).get("es", {}).get("stringUnit", {}).get("value")


def merge(files):
    cat = load()
    bad = 0
    for f in files:
        pairs = json.loads(Path(f).read_text())
        for en, es in pairs.items():
            if not isinstance(es, str) or not es.strip():
                print(f"EMPTY {f}: {en!r}")
                bad += 1
                continue
            if SPEC.findall(en) != SPEC.findall(es):
                # Positional specifiers (%1$@) may reorder; same multiset is fine.
                strip = lambda xs: sorted(re.sub(r"\d+\$", "", x) for x in xs)
                if strip(SPEC.findall(en)) != strip(SPEC.findall(es)):
                    print(f"FORMAT MISMATCH {f}: {en!r} -> {es!r}")
                    bad += 1
                    continue
            cat["strings"][en] = {
                "extractionState": "manual",
                "localizations": {"es": {"stringUnit": {"state": "translated", "value": es}}},
            }
    save(cat)
    print(f"catalog: {len(cat['strings'])} strings, {bad} rejected")
    return 1 if bad else 0


LITERAL = re.compile(
    r'(?:\bText|\bButton|\bLabel|\bToggle|\bLink|accessibilityLabel|accessibilityHint|accessibilityValue|navigationTitle|\.alert|\.confirmationDialog|Section|Picker|TextField|announcement, argument:)\(\s*"((?:[^"\\\n]|\\.)*[A-Za-z]{2}(?:[^"\\\n]|\\.)*)"'
)


def literals():
    hits = 0
    for p, rel in swift_files():
        for n, line in enumerate(p.read_text().splitlines(), 1):
            s = line.strip()
            if s.startswith("//") or "accessibilityIdentifier" in s and "accessibilityLabel" not in s:
                continue
            for m in LITERAL.finditer(line):
                print(f"{rel}:{n}: {m.group(1)[:90]}")
                hits += 1
    print(f"{hits} literal(s)", file=sys.stderr)
    return 1 if hits else 0


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "missing"
    if cmd == "keys":
        for k, where in sorted(keys().items()):
            print(f"{where}\t{k}")
    elif cmd == "missing":
        cat = load()
        miss = {k: w for k, w in keys().items() if not spanish(cat, k)}
        for k, w in sorted(miss.items(), key=lambda kv: kv[1]):
            print(f"{w}\t{k}")
        print(f"{len(miss)} missing of {len(keys())}", file=sys.stderr)
        return 1 if miss else 0
    elif cmd == "merge":
        return merge(sys.argv[2:])
    elif cmd == "literals":
        return literals()
    elif cmd == "stale":
        used = keys()
        for k in load()["strings"]:
            if k not in used:
                print(k)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
