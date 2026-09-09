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
        // Crash guard for odd GPU drivers: a marker file is left on disk while
        // the GPU path is being tried. If the app died inside the driver the
        // marker is still there next launch, and that phone stays on the CPU.
        val marker = File(appContext.filesDir, GPU_ATTEMPT_MARKER)
        val useGpu = !marker.exists()
        if (!useGpu) Log.w(TAG, "a previous GPU attempt never finished; staying on the CPU")
        if (useGpu) marker.writeText("trying")
        handle = NarratorNative.nativeInit(model.absolutePath, mmproj.absolutePath, threads, useGpu)
        // We came back at all, so the driver did not take the process down;
        // a plain failure is reported by the return value, not the marker.
        marker.delete()
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
        if (File(local, MODEL_FILE).isFile && File(local, MMPROJ_FILE).isFile) return local
        return apkAssetsDirectory(local)
    }

    /**
     * Third home for the weights: a universal or sideloaded APK carries the
     * asset pack's two files inside its own assets/, and Play's install-time
     * packs are reachable the same way. llama.cpp needs a real path, so they
     * are copied out once into app storage and reused on every later open.
     */
    private fun apkAssetsDirectory(local: File): File? {
        val assets = appContext.assets
        val present = try { assets.list("")?.toSet() ?: emptySet() } catch (t: Throwable) { emptySet() }
        if (MODEL_FILE !in present || MMPROJ_FILE !in present) {
            Log.w(TAG, "no model in the asset pack, app storage or the APK itself")
            return null
        }
        local.mkdirs()
        for (name in listOf(MODEL_FILE, MMPROJ_FILE)) {
            val dst = File(local, name)
            if (dst.isFile) continue
            val tmp = File(local, "$name.part")
            try {
                assets.open(name).use { src ->
                    tmp.outputStream().use { src.copyTo(it, 1 shl 20) }
                }
                if (!tmp.renameTo(dst)) throw java.io.IOException("rename failed for $name")
                Log.i(TAG, "copied $name out of the APK (${dst.length()} bytes)")
            } catch (t: Throwable) {
                Log.e(TAG, "copying $name out of the APK failed", t)
                tmp.delete()
                return null
            }
        }
        return local
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

    /**
     * 32-bit phones cannot map 736 MB of weights, the kernels are aarch64, and
     * the Vulkan build links the Android 9 (API 28) libvulkan.
     */
    private fun supportedDevice(): Boolean =
        Build.SUPPORTED_64_BIT_ABIS.isNotEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P

    companion object {
        private const val TAG = "NarratorEngine"
        private const val PACK_NAME = "vision_model"
        private const val LOCAL_DIR = "narrator"
        private const val GPU_ATTEMPT_MARKER = "narrator-gpu-attempt"
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
