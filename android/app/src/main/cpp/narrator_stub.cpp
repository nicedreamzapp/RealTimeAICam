// 32-bit ABIs cannot run the vision narrator (736 MB of weights, and llama.cpp's
// fp16 kernels need aarch64). NarratorEngine treats a 0 handle as "unavailable"
// and the What's this? tile stays hidden.
#include <jni.h>

extern "C" {
JNIEXPORT jlong JNICALL
Java_com_mattmacosko_realtimeaicam_narrator_NarratorNative_nativeInit(
        JNIEnv *, jobject, jstring, jstring, jint) { return 0; }

JNIEXPORT jstring JNICALL
Java_com_mattmacosko_realtimeaicam_narrator_NarratorNative_nativeDescribe(
        JNIEnv * env, jobject, jlong, jstring, jstring, jstring, jint) {
    return env->NewStringUTF("");
}

JNIEXPORT void JNICALL
Java_com_mattmacosko_realtimeaicam_narrator_NarratorNative_nativeFree(
        JNIEnv *, jobject, jlong) {}
}
