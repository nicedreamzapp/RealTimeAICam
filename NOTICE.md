# Notice

RealTime AI Cam
Copyright (C) 2025-2026 Matt Macosko / Nice Dreamz LLC

The source code in this repository is licensed under the GNU Affero General Public
License v3.0 ([LICENSE](LICENSE)). You may use, study, modify and share it under those
terms, which include sharing your modified source with anyone you distribute it to or
serve it to over a network.

## Name and icon

The name "RealTime AI Cam" (also written "RealTime AI Camera") and the app icon are not
licensed under the AGPL or anything else. If you publish a build of this code, give it a
different name and icon.

## Third-party work

- **YOLOv8** by Ultralytics, licensed under AGPL-3.0: https://github.com/ultralytics/ultralytics
- **Open Images Dataset V7** by Google, licensed under CC BY 4.0:
  https://storage.googleapis.com/openimages/web/index.html
- **LFM3-Omni-2B** by Liquid AI, Inc., the What's this? vision model (iOS 1.3.6 and Android 1.23
  onward), used untrained under the **LFM Open License v1.0**: https://huggingface.co/LiquidAI/LFM3-Omni-2B.
  The full license ships inside both apps (VisionModel/LFM-Open-License-v1.0.txt on iPhone,
  assets/licenses/ on Android) and can be read from their settings/instructions. Changed by Nice Dreamz
  LLC: converted to GGUF and quantized (IQ2_XS text model, Q4_K_M vision projector); weights otherwise
  unchanged.
- **llama.cpp** by ggml-org, licensed under MIT: https://github.com/ggml-org/llama.cpp

See [CREDITS.md](CREDITS.md) for everyone else this app is built on.
