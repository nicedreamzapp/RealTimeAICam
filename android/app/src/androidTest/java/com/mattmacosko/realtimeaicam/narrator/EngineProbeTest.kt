package com.mattmacosko.realtimeaicam.narrator

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mattmacosko.realtimeaicam.ui.prepareShot
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Test-only engine probe: the native engine with a chosen thread count, GPU flag
 * and mmproj file, on a few scene photos (plain scene question, no retries).
 * Args: -e threads 8 -e gpu false -e mmproj <file in files/narrator> -e sceneSide 512
 *       -e photos m01.jpg,m05.jpg -e tag name. Writes files/photo-test/probe-<tag>.jsonl.
 */
@RunWith(AndroidJUnit4::class)
class EngineProbeTest {
    @Test
    fun probe() {
        val args = InstrumentationRegistry.getArguments()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val threads = args.getString("threads")?.toIntOrNull() ?: 8
        val gpu = args.getString("gpu") == "true"
        val side = args.getString("sceneSide")?.toIntOrNull() ?: 512
        val tag = args.getString("tag") ?: "probe"
        val dir = File(context.filesDir, "narrator")
        val mmproj = File(dir, args.getString("mmproj") ?: NarratorEngine.MMPROJ_FILE)
        val model = File(dir, NarratorEngine.MODEL_FILE)
        val photoDir = File(context.filesDir, "photo-test")
        val names = args.getString("photos")?.split(",") ?: listOf("m01.jpg")
        assertTrue(NarratorNative.load())
        val t0 = System.currentTimeMillis()
        val h = NarratorNative.nativeInit(model.absolutePath, mmproj.absolutePath, threads, gpu, true)
        assertTrue("init failed", h != 0L)
        val loadMs = System.currentTimeMillis() - t0
        val out = File(photoDir, "probe-$tag.jsonl")
        out.delete()
        for (n in names) {
            val shot = File(context.cacheDir, "probe-shot.jpg")
            if (prepareShot(File(photoDir, n), shot) == null) continue
            val img = resized(shot, side)
            val started = System.currentTimeMillis()
            val text = NarratorNative.nativeDescribe(h, img.absolutePath, NarratorPrompt.SYSTEM, NarratorPrompt.SCENE_QUESTION, 120)
            val wall = System.currentTimeMillis() - started
            val st = NarratorNative.nativeLastStats(h).split(",")
            val row = JSONObject().put("tag", tag).put("image", n).put("threads", threads).put("gpu", gpu)
                .put("mmproj", mmproj.name).put("side", side).put("text", text)
                .put("ttftMs", st.getOrNull(0)).put("totalNativeMs", st.getOrNull(1)).put("encodeMs", st.getOrNull(2))
                .put("promptTokens", st.getOrNull(3)).put("genTokens", st.getOrNull(4)).put("wallMs", wall)
                .put("loadMs", loadMs).put("peakKb", peakKb())
            out.appendText(row.toString() + "\n")
            Log.i("EngineProbe", "RESULT $row")
        }
        NarratorNative.nativeFree(h)
    }

    private fun resized(shot: File, side: Int): File {
        val bitmap = BitmapFactory.decodeFile(shot.path, BitmapFactory.Options()) ?: return shot
        val long = max(bitmap.width, bitmap.height)
        if (long <= side) { bitmap.recycle(); return shot }
        val s = side.toFloat() / long
        val scaled = Bitmap.createScaledBitmap(bitmap, (bitmap.width * s).roundToInt(), (bitmap.height * s).roundToInt(), true)
        val out = File(shot.parentFile, "probe-scene.jpg")
        out.outputStream().use { scaled.compress(Bitmap.CompressFormat.JPEG, 90, it) }
        if (scaled !== bitmap) scaled.recycle()
        bitmap.recycle()
        return out
    }

    private fun peakKb(): Long = try {
        File("/proc/self/status").readLines().firstOrNull { it.startsWith("VmHWM:") }
            ?.replace(Regex("[^0-9]"), "")?.toLong() ?: -1
    } catch (t: Throwable) { -1 }
}
