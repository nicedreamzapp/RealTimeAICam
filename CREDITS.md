# 🙏 Credits

None of this starts from scratch. Here's whose work this is built on, and under what terms.

| Project | What it does here | By | License |
|---|---|---|---|
| 👁️ [YOLOv8](https://github.com/ultralytics/ultralytics) | The 601-class detector | Ultralytics | **AGPL-3.0** |
| 🗂️ [Open Images](https://storage.googleapis.com/openimages/web/index.html) | The class vocabulary it was trained against | Google | CC BY 4.0 (annotations) |
| 🍎 [Core ML](https://developer.apple.com/documentation/coreml) + Vision | Runs it all on-device | Apple | Apple SDK terms |

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
