# RealTime AI Cam -- R8 keep rules
# Play requires a minimum of 25% DEX coverage from February 2027; minifyEnabled false
# is 0%. Everything here exists because R8 breaks this app at RUNTIME, not at build time.

# --- TensorFlow Lite ---
# The interpreter is reached over JNI and by reflection. R8 cannot see native call sites,
# so stripping or renaming these produces a build that loads the model and then crashes.
-keep class org.tensorflow.** { *; }
-keep class org.tensorflow.lite.** { *; }
-keepclasseswithmembernames class * { native <methods>; }
-dontwarn org.tensorflow.**

# --- ML Kit / CameraX / Play Services (reflective service loading) ---
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**
-keep class androidx.camera.** { *; }

-keep class com.mattmacosko.realtimeaicam.** { *; }
-keepattributes *Annotation*,SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
