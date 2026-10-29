# What's this? on llama.cpp (since 1.3.6)

The vision model is LFM3-Omni-2B by Liquid AI, untrained, under the LFM Open License v1.0.
It runs through llama.cpp's C API (`project 601/LlamaVisionEngine.swift`), the same engine,
prompt string, context sizes and greedy loop as the Android app (`android/app/src/main/cpp/narrator_jni.cpp`).

Two things live outside git and must be put in place before a build:

- `ios/Frameworks/llama.xcframework`: llama.cpp tag b11954 (LFM3 support merged 10/27), built with
  `./build-xcframework.sh` from the llama.cpp checkout (ios-arm64, ios-arm64_x86_64-simulator, macos slices).
- `ios/VisionModel/` (folder reference, copy never symlink): `lfm3-omni-2b-IQ2_XS.gguf`,
  `lfm3-omni-2b-mmproj-vision-Q4_K_M.gguf`, `LFM-Open-License-v1.0.txt`, `README.md`, and
  `manifest.json` from `tools/make_manifest.py ios/VisionModel --version lfm3-omni-2b-iq2xs-v1`.

GGUFs: converted from the Hugging Face weights with llama.cpp's `convert_hf_to_gguf.py` (text model,
and `--mmproj` for the vision-only projector), then `llama-quantize` to IQ2_XS with an importance
matrix from llama.cpp's general calibration text, and Q4_K_M for the projector.
sha256: e93f6fb3…8a41e (text), 350ba2b5…84010 (projector).

On-phone test: launch with `-rtcamPhotoTest`; it reads Documents/photo-test/*.jpg and writes
Documents/photo-test/results.jsonl (route, answer, first token, total, passes, peak footprint).

## Android (1.23 onward)

`android/app/src/main/jniLibs/arm64-v8a/` (gitignored) holds llama.cpp b11954 built with the NDK
29.0.14206865 toolchain: `-DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-28 -DBUILD_SHARED_LIBS=ON
-DGGML_OPENMP=OFF -DGGML_NATIVE=OFF -DGGML_VULKAN=ON -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON
-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384` (glslc from the NDK's shader-tools,
`-DSPIRV-Headers_DIR` pointing at Homebrew's spirv-headers); copy the six .so files and the
llama/ggml/mtmd headers into `app/src/main/cpp/include/`. The two GGUFs go in
`android/vision_model/src/main/assets/` (install-time asset pack).
