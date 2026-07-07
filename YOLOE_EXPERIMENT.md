# YOLOE Experiment — Findings & Retuning Guide

**Date:** July 7, 2026
**Branch:** `yoloe-experiment` (main was reverted to the 1.0.16 (19) App Store submission)
**Status:** Working prototype, over-detects. Needs confidence retuning before release.

## What this branch contains

An upgrade from YOLOv8-OIV7 (601 classes) to **YOLOE-11s prompt-free**
(4,585 classes, open-vocabulary) as the live detector:

- `yoloe11s_pf.mlpackage` — YOLOE converted to CoreML with decode baked into
  the graph. Outputs per anchor: `confidence [1,8400]`, `class_id [1,8400]
  int32`, `boxes xywh in 640px [1,4,8400]`. Input: 640×640 RGB, same spec as
  the old model, so the Metal letterbox/channel path needed zero changes.
- `yoloe_class_names.txt` — 4,585 labels, first-letter-capitalized at load to
  match OIV7 style so the priority/context/indoor/outdoor sets keep matching
  where vocabularies overlap.
- `YOLOv8Processor.swift` — dual-model: YOLOE preferred on iOS 17+, YOLOv8
  fallback below (stored as `Any` behind availability guards). The original
  tuned decode pipeline was extracted into `decodeCore` and is shared by both
  models; only tensor unpacking differs (`decodeYOLOEOutput`).

The conversion recipe lives in the Vision Builder repo
(`scripts/convert_yoloe.py`) with hard-won notes: topk/gather in-graph falls
off the ANE (99ms), max over dim=1 places badly (124ms), transpose-then-max
over the last axis stays on ANE (22ms/45fps on M4 Pro), and class_id must be
int32 because fp16 can't represent ids above 2048.

## What went wrong on device

**Massive over-detection — boxes on things that aren't there.**

Root cause: the app's detection thresholds were tuned for YOLOv8-OIV7's score
distribution and are very aggressive:

```
effective threshold = baseThreshold (0.20) × confidenceThreshold (~0.5 default)  ≈ 0.10
  × 0.7 if class is in priorityHouseholdItems                                    ≈ 0.07
  × 0.6 if a context pair is present ("Laptop" seen → boost "Mouse")             ≈ 0.04–0.06
```

A floor of 0.04–0.10 works for a 601-class model whose false candidates score
very low. YOLOE spreads probability over 4,585 classes with an open-vocab
head — it emits far more anchors in the 0.05–0.30 range that are noise.
Feeding those through the same multipliers floods the screen.

Supporting data point: in Vision Builder, the same model is gated at **0.35**
minimum confidence and behaves well on stills (bus test: person 0.94, bus
0.86, glasses 0.70 — clean).

## Retuning plan (in order of expected payoff)

1. **Raise the YOLOE floor.** Add a model-specific base: keep
   `baseThreshold = 0.20` for v8, use **0.35–0.45** for YOLOE, applied BEFORE
   the priority/context multipliers. Start at 0.40 and walk down.
2. **Cap the multiplier stack for YOLOE.** Priority (×0.7) and context (×0.6)
   multipliers compound. For YOLOE either disable them or floor the final
   threshold at ~0.30 regardless of multipliers.
3. **Per-anchor top-k budget.** YOLOE emits more plausible-looking anchors;
   consider dropping `maxRawDetections` 150 → 60 and `maxDetectionsPerFrame`
   40 → 20 for the 4,585-class head.
4. **Class allow-list mode.** YOLOE's superpower is breadth, but 4,585 classes
   includes a lot of exotic noise ("balance beam" in a living room). A curated
   deny-list of chronic false-positive classes — or an allow-list per filter
   mode — could ship quality fast.
5. **If still noisy:** the model itself can be re-exported with a smaller
   vocabulary via `set_classes` (e.g. 1,000 curated household/outdoor labels)
   — smaller head, higher precision, faster too.

## How to test next time

- Build this branch to the phone, point at a normal room, count boxes.
  Success bar: no more phantom objects than the shipped v8 build.
- The threshold lives in `YOLOv8Processor.swift` (`baseThreshold`, plus the
  multiplier logic in `decodeCore`). One-line experiments, quick rebuilds.
- Offline check without a phone: Vision Builder repo,
  `.venv-models` + `scripts/convert_yoloe.py` verification block runs the
  model on a test image and prints scored detections.

## Revert record

- `main` was reverted to match the 1.0.16 (19) App Store submission exactly
  (commit `29c94c1`), plus README updates (fixed clone URL and star/fork
  badges that pointed at the wrong repo; experiment note pointing here).
- The phone was reinstalled with the reverted build.
