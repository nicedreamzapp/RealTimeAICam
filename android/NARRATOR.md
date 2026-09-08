# What's this? — the on-device vision narrator

The purple **What's this?** button takes one photo and speaks one sentence about it:
what a bill is and what it costs, or what room you are standing in. It is the same
fine-tuned model the iOS app runs, and like iOS it never touches the network.

Two pieces are deliberately **not** in git — together they are about 750 MB.

## 1. llama.cpp, cross-compiled for Android

Rebuilds `app/src/main/jniLibs/arm64-v8a/{libllama,libmtmd,libggml,libggml-base,libggml-cpu}.so`
and the headers `app/src/main/cpp/include/` that `narrator_jni.cpp` includes.

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
NDK=$ANDROID_HOME/ndk/29.0.14206865
cmake -B build-android \
  -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
  -DGGML_OPENMP=OFF -DLLAMA_CURL=OFF
cmake --build build-android -j --target llama mtmd

cp build-android/bin/*.so   <app>/src/main/jniLibs/arm64-v8a/
cp include/llama.h ggml/include/*.h tools/mtmd/mtmd*.h  <app>/src/main/cpp/include/
```

**arm64 only.** `sgemm.cpp` does not compile for `armeabi-v7a` (`vld1q_f16` undeclared),
and 736 MB of weights will not map on a 32-bit phone anyway. `CMakeLists.txt` builds
`narrator_stub.cpp` for every other ABI so the APK still links, and `NarratorEngine`
reports the feature unavailable there.

## 2. The model

`vision_model/src/main/assets/` holds `narrator-Q4_K_M.gguf` (529 MB) and
`narrator-mmproj-f16.gguf` (207 MB). They are produced by merging the trained LoRA onto
the stock `Qwen/Qwen3.5-0.8B` and converting with llama.cpp's `convert_hf_to_gguf.py`
(`--no-mtp` for the text half, `--mmproj` for the vision half, then `llama-quantize`
to `Q4_K_M`). Do **not** convert the MLX-fused checkpoint that iOS ships: the shapes all
match and the output is still garbage, because llama.cpp re-orders the linear-attention
V block assuming HuggingFace ordering.

Leave the mmproj at f16. Quantizing this model's vision tower was measured to cost
several points of accuracy.

`vision_model` is a Play **install-time** asset pack, so the weights are on the phone
before the app first opens — no download screen and nothing to host. `NarratorEngine`
locates them through `AssetPackManager`, falling back to `filesDir/narrator/` so a
sideloaded debug build can be handed the same two files with `adb push`.

## Testing without a camera

`app/src/androidTest/.../NarratorSmokeTest.kt` runs the real model over photos placed in
the app's own `files/narrator-test/` and logs each answer with its timing, which exercises
the whole native path with no camera involved.
