# 🙏 Credits

None of this starts from scratch. Here's whose work this is built on, and under what terms.

| Project | What it does here | By | License |
|---|---|---|---|
| 👁️ [YOLOv8](https://github.com/ultralytics/ultralytics) | The 601-class detector | Ultralytics | **AGPL-3.0** |
| 🗂️ [Open Images](https://storage.googleapis.com/openimages/web/index.html) | The class vocabulary it was trained against | Google | CC BY 4.0 (annotations) |
| 🍎 [Core ML](https://developer.apple.com/documentation/coreml) + Vision | Runs it all on-device | Apple | Apple SDK terms |
| 💧 [LFM3-Omni-2B](https://huggingface.co/LiquidAI/LFM3-Omni-2B) | The What's this? vision model, untrained, shrunk to GGUF IQ2_XS + Q4_K_M | Liquid AI | LFM Open License v1.0 |
| 🦙 [llama.cpp](https://github.com/ggml-org/llama.cpp) | Runs the vision model on the phone | ggml-org | MIT |
| 💵 Live Cam money reader (`ios/MoneyModels`) | Counts and reads US bills: a YOLO26n-OBB detector and a YOLO26n-cls classifier, fine-tuned from [Ultralytics](https://github.com/ultralytics/ultralytics) weights | Ultralytics (base models) | **AGPL-3.0** |
| 🏛️ [uscurrency.gov](https://www.uscurrency.gov/denominations) note images | Textures for the money reader's synthetic training pictures | U.S. Currency Education Program, Federal Reserve Board | US government work (17 U.S.C. 105) |
| 🌄 [Poly Haven](https://polyhaven.com) | HDRIs and surfaces for those pictures | Poly Haven | CC0 |
| 📷 [COCO 2017](https://cocodataset.org) | Photos with no money in them, so the reader learns what isn't a bill | COCO Consortium and Flickr authors | CC BY / CC BY-SA (per image), annotations CC BY 4.0 |
| 💲 [Currency V4F8J](https://universe.roboflow.com/roboflow-100/currency-v4f8j) | Real single-bill photos for the classifier | Alex Hyams, Roboflow 100 | CC BY 4.0 |

## Why this app is open source

YOLOv8 is **AGPL-3.0**. Ultralytics is explicit that compliance means publishing the
complete source of the derivative work, including model weights, and that it applies even
when embedded in a product. That's why the full iOS and Android source and the converted
models are in this repository rather than kept private.

If you're building on this, inherit that obligation seriously — or get a commercial license
from Ultralytics for closed-source use.

---

If your work is listed here and you'd like the wording changed, or if something's
missing or wrong, open an issue and I'll fix it.
