# RealTime AI Cam -- R8 keep rules (vc24 / 1.19, first R8 build of this app)
# Play requires >= 25% DEX obfuscation from February 2027. Every rule below exists because
# R8 would break the app at RUNTIME (JNI, reflection, XML), not at build time. Keep them narrow:
# a blanket keep on our own package is what held obfuscation at 1%.

# --- Narrator JNI (libnarrator.so) ---
# narrator_jni.cpp exports Java_com_mattmacosko_realtimeaicam_narrator_NarratorNative_native*,
# resolved BY NAME at first call. Class name, package and the three native methods must not change.
# The C side never calls back into Java (no FindClass / GetMethodID), so nothing else is needed.
-keep class com.mattmacosko.realtimeaicam.narrator.NarratorNative { *; }
-keepclasseswithmembernames,includedescriptorclasses class * { native <methods>; }

# --- Play Asset Delivery (install-time vision_model pack) ---
# NarratorEngine reaches AssetPackManagerFactory.getInstance / getPackLocation / assetsPath
# by reflection on the runtime (impl) class, which R8 cannot trace.
-keep class com.google.android.play.core.assetpacks.** { *; }
-dontwarn com.google.android.play.core.**

# --- Entry points named in XML ---
# MainActivity is the launcher and the targetClass of every static shortcut / App Actions
# capability in res/xml/shortcuts.xml (AAPT keeps manifest classes; this pins it for shortcuts).
-keep class com.mattmacosko.realtimeaicam.MainActivity { *; }

# --- TensorFlow Lite + GPU delegate ---
# The interpreter calls back into Java from native code, and GpuDelegateFactory is
# found reflectively; renaming either loads the model and then crashes.
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.**
-dontwarn com.google.auto.value.**

# --- ML Kit (text recognition, face detection, translate) ---
# Components are registered by reflection (ComponentRegistrar) and the bundled models use
# protobuf-lite, which reads fields by name.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-keep class * extends com.google.android.gms.internal.mlkit_vision_common.zz** { *; }
-keep class com.google.firebase.components.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**

# --- CameraX ---
# Camera2 config provider is loaded reflectively from the manifest meta-data.
-keep class androidx.camera.camera2.Camera2Config$DefaultProvider { *; }
-keep class androidx.camera.core.impl.** { *; }

-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod,SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
