# What's this? — the on-device vision narrator

The purple **What's this?** button takes one photo and speaks one sentence about it:
what a bill is and what it costs, or what room you are standing in. It is the same
fine-tuned model the iOS app runs, and like iOS it never touches the network.

Two pieces are deliberately **not** in git — together they are about 750 MB.

## 1. llama.cpp, cross-compiled for Android (CPU + Vulkan)

Rebuilds `app/src/main/jniLibs/arm64-v8a/{libllama,libmtmd,libggml,libggml-base,libggml-cpu,libggml-vulkan}.so`
and the headers `app/src/main/cpp/include/` that `narrator_jni.cpp` includes.

Since 1.3 the build carries the Vulkan backend so phones with a capable GPU run the
model there. It needs three things the NDK does not ship: the Vulkan C++ headers
(`vulkan.hpp`), SPIRV-Headers, and `glslc` (that one IS in the NDK's `shader-tools`).
On a Mac: `brew install vulkan-headers spirv-headers`.

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
NDK=$ANDROID_HOME/ndk/29.0.14206865
HOST=darwin-x86_64            # linux-x86_64 on Linux
cmake -B build-android \
  -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-28 \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
  -DGGML_OPENMP=OFF -DLLAMA_CURL=OFF \
  -DGGML_VULKAN=ON \
  -DVulkan_GLSLC_EXECUTABLE=$NDK/shader-tools/$HOST/glslc \
  -DVulkan_INCLUDE_DIR=$(brew --prefix vulkan-headers)/include \
  -DVulkan_LIBRARY=$NDK/toolchains/llvm/prebuilt/$HOST/sysroot/usr/lib/aarch64-linux-android/28/libvulkan.so \
  -DSPIRV-Headers_DIR=$(brew --prefix)/lib/cmake/SPIRV-Headers \
  -DCMAKE_FIND_ROOT_PATH=$(brew --prefix) \
  "-DCMAKE_CXX_FLAGS=-I$(brew --prefix spirv-headers)/include"
cmake --build build-android -j --target llama mtmd ggml-vulkan

cp build-android/bin/*.so   <app>/src/main/jniLibs/arm64-v8a/
cp include/llama.h ggml/include/*.h tools/mtmd/mtmd*.h  <app>/src/main/cpp/include/
```

Why `android-28`: the API-26 `libvulkan.so` is Vulkan 1.0 and lacks
`vkGetPhysicalDeviceFeatures2`, which ggml needs. `NarratorEngine` therefore
requires Android 9+ for the feature (older phones just do not get the tile).

**The GPU is probed, never assumed.** `narrator_jni.cpp` lists ggml's devices, tries
`ggml_backend_dev_init` on each GPU inside a try/catch, and hands llama an explicit
`devices` list. That matters: a driver ggml rejects (the PowerVR GE8320 has no 16-bit
storage buffers and throws "Unsupported device") would otherwise make llama refuse to
load the model even for a CPU run. A phone whose driver crashes the process leaves a
marker file behind, and `NarratorEngine` keeps that phone on the CPU from then on.
llama's own log lines go to logcat under the tag `llama`.

Measured so far: a Helio P35 (8x Cortex-A53, GPU refused) answers in about 87 s with the
model shown a 512 px copy of the photo. No GPU-capable phone has been timed yet.

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
locates them through `AssetPackManager`, then `filesDir/narrator/`, and finally the
APK's own `assets/` (a `bundletool --mode=universal` build packs the asset pack in there),
copying the two files out once so llama.cpp gets a real path. That last fallback is what
makes a sideloaded universal APK work.

## Testing without a camera

`app/src/androidTest/.../NarratorSmokeTest.kt` runs the real model over photos placed in
the app's own `files/narrator-test/` and logs each answer with its timing, which exercises
the whole native path with no camera involved.
