#!/usr/bin/env python3
"""Build es_idioms.json, the whole-clause idiom list used before the system
translator (iOS SpanishIdiomPrepass.swift, Android SpanishIdiomPrepass.kt).

Source: the top-level "phrases" map of es_final_with_rules.json.gz. Kept: 3+
words, and not an infinitive gloss ("to sleep on it"), since only a whole
sentence or clause is ever replaced. Keys are normalized exactly like the
apps do it: lowercase, accents folded, punctuation to spaces, spaces collapsed.

usage: make-es-idioms.py es_final_with_rules.json.gz es_idioms.json
"""
import gzip, json, re, sys, unicodedata

def norm(s):
    s = unicodedata.normalize("NFD", s.lower())
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    s = re.sub(r"[^\w\s]", " ", s)
    return re.sub(r"\s+", " ", s).strip()

src, out = sys.argv[1], sys.argv[2]
data = json.load(gzip.open(src))
idioms = {}
for k, v in sorted(data["phrases"].items()):
    v = (v or "").strip()
    nk = norm(k)
    if len(nk.split()) >= 3 and v and not v.lower().startswith("to "):
        idioms.setdefault(nk, v)
json.dump(idioms, open(out, "w"), ensure_ascii=False, sort_keys=True, separators=(",", ":"))
print(len(idioms), "idioms")
