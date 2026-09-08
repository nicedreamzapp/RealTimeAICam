package com.mattmacosko.realtimeaicam.narrator

/**
 * Thin JNI surface over llama.cpp + mtmd. Everything here is blocking and must
 * be called off the main thread; NarratorEngine owns that discipline.
 */
internal object NarratorNative {
    @Volatile private var loaded = false

    fun load(): Boolean {
        if (loaded) return true
        return try {
            System.loadLibrary("narrator")
            loaded = true
            true
        } catch (t: Throwable) {
            false
        }
    }

    external fun nativeInit(modelPath: String, mmprojPath: String, threads: Int): Long
    external fun nativeDescribe(
        handle: Long,
        imagePath: String,
        system: String,
        question: String,
        maxTokens: Int,
    ): String
    external fun nativeFree(handle: Long)
}
