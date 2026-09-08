package com.mattmacosko.realtimeaicam.narrator

import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File

/**
 * Owns the on-device vision model: where its two files live, when they are
 * loaded, and the one blocking call that turns a photo into a spoken sentence.
 *
 * Nothing here touches the network. The weights ship with the app as a Play
 * install-time asset pack, so the phone already has them the moment the app
 * opens, exactly like the iPhone build.
 */
class NarratorEngine private constructor(private val appContext: Context) {

    private var handle: Long = 0L

    val isAvailable: Boolean get() = handle != 0L

    /** Blocking: loads ~736 MB off storage. Call from a background thread. */
    @Synchronized
    fun ensureLoaded(): Boolean {
        if (handle != 0L) return true
        if (!supportedDevice()) return false
        if (!NarratorNative.load()) return false

        val dir = modelDirectory() ?: return false
        val model = File(dir, MODEL_FILE)
        val mmproj = File(dir, MMPROJ_FILE)
        if (!model.isFile || !mmproj.isFile) {
            Log.w(TAG, "model files missing under ${dir.absolutePath}")
            return false
        }

        val threads = Runtime.getRuntime().availableProcessors().coerceIn(2, 6)
        handle = NarratorNative.nativeInit(model.absolutePath, mmproj.absolutePath, threads)
        return handle != 0L
    }

    /** Blocking. Returns "" when the model could not answer. */
    fun describe(photo: File, question: String): String {
        if (!ensureLoaded()) return ""
        return try {
            NarratorNative.nativeDescribe(
                handle, photo.absolutePath,
                NarratorPrompt.SYSTEM, question, MAX_TOKENS,
            )
        } catch (t: Throwable) {
            Log.e(TAG, "describe failed", t)
            ""
        }
    }

    @Synchronized
    fun release() {
        if (handle != 0L) {
            NarratorNative.nativeFree(handle)
            handle = 0L
        }
    }

    /**
     * The install-time asset pack first, then a plain folder in app storage so a
     * sideloaded debug build can be fed the same two files by hand.
     */
    private fun modelDirectory(): File? {
        assetPackDirectory()?.let { return it }
        val local = File(appContext.filesDir, LOCAL_DIR)
        return if (File(local, MODEL_FILE).isFile) local else null
    }

    private fun assetPackDirectory(): File? = try {
        val managerClass = Class.forName("com.google.android.play.core.assetpacks.AssetPackManagerFactory")
        val manager = managerClass.getMethod("getInstance", Context::class.java).invoke(null, appContext)
        val location = manager!!.javaClass.getMethod("getPackLocation", String::class.java)
            .invoke(manager, PACK_NAME)
        val path = location?.javaClass?.getMethod("assetsPath")?.invoke(location) as? String
        path?.let { File(it) }?.takeIf { File(it, MODEL_FILE).isFile }
    } catch (t: Throwable) {
        // Play Core absent (debug build, sideload): fall through to app storage.
        null
    }

    /** 32-bit phones cannot map 736 MB of weights, and the kernels are aarch64. */
    private fun supportedDevice(): Boolean = Build.SUPPORTED_64_BIT_ABIS.isNotEmpty()

    companion object {
        private const val TAG = "NarratorEngine"
        private const val PACK_NAME = "vision_model"
        private const val LOCAL_DIR = "narrator"
        const val MODEL_FILE = "narrator-Q4_K_M.gguf"
        const val MMPROJ_FILE = "narrator-mmproj-f16.gguf"
        private const val MAX_TOKENS = 120

        @Volatile private var instance: NarratorEngine? = null

        fun get(context: Context): NarratorEngine =
            instance ?: synchronized(this) {
                instance ?: NarratorEngine(context.applicationContext).also { instance = it }
            }
    }
}
