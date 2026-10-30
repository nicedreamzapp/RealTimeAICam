package com.mattmacosko.realtimeaicam.narrator

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mattmacosko.realtimeaicam.ui.describeNeverRefusing
import com.mattmacosko.realtimeaicam.ui.looksLikeAPage
import com.mattmacosko.realtimeaicam.ui.prepareShot
import com.mattmacosko.realtimeaicam.ui.sizedForModel
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * A folder of photos through the same path a What's this? press takes, minus
 * the camera: prepareShot (upright, 1024 px), looksLikeAPage (ML Kit), the
 * page or scene question, sizedForModel, describeNeverRefusing with its retries.
 * One JSON line per photo: route, answer, first-token time, total time, every
 * native pass, and the process's peak memory so far (VmHWM).
 *
 * Photos go in files/photo-test/ beforehand (adb push + run-as cp); results are
 * written to files/photo-test/results.jsonl and logged under PhotoSetPhoneTest.
 * The photos are private: nothing here sends them anywhere.
 */
@RunWith(AndroidJUnit4::class)
class PhotoSetPhoneTest {

    @Test
    fun answersPhotoSet() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val engine = NarratorEngine.get(context)
        val dir = File(context.filesDir, "photo-test")
        val photos = dir.listFiles { f -> f.name.endsWith(".jpg") }?.sortedBy { it.name }
        assertTrue("no test photos at $dir", !photos.isNullOrEmpty())

        val sceneSide = InstrumentationRegistry.getArguments().getString("sceneSide")?.toIntOrNull() ?: 0
        // "-e level quick|balanced|clear|sharp" forces a level; otherwise the picker chooses (1.24).
        val levelArg = ModelLevel.fromKey(InstrumentationRegistry.getArguments().getString("level"))
        Log.i(TAG, "sceneSide override: $sceneSide")
        val loadStart = System.currentTimeMillis()
        assertTrue("model failed to load", engine.ensureLoaded())
        val loadMs = System.currentTimeMillis() - loadStart
        Log.i(TAG, "model load $loadMs ms, peak ${peakKb()} kB")
        engine.recordStats = true

        val out = File(dir, "results.jsonl")
        out.delete()
        for (photo in photos!!) {
            val shot = File(context.cacheDir, "photo-test-shot.jpg")
            val started = System.currentTimeMillis()
            if (prepareShot(photo, shot) == null) {
                Log.e(TAG, "could not prepare ${photo.name}")
                continue
            }
            val isPage = runBlocking { looksLikeAPage(context, shot) }
            val question = if (isPage) NarratorPrompt.PAGE_QUESTION else NarratorPrompt.SCENE_QUESTION
            // Test-only: "-e sceneSide 512" resizes the scene copy from the 1024 px shot
            // exactly the way sizedForModel does, just to a different long side.
            val forModel = if (!isPage && sceneSide > 0) resized(shot, sceneSide) else sizedForModel(context, shot, isPage)
            engine.statsLog.clear()
            val level = levelArg ?: ModelPicker.level(context, if (isPage) PhotoKind.PAGE else PhotoKind.SCENE)
            engine.select(level)
            val said = describeNeverRefusing(context, forModel, question, isPage, engine)
            val wallMs = System.currentTimeMillis() - started
            val passes = engine.statsLog.toList()
            val first = passes.firstOrNull()?.split(",")
            val row = JSONObject()
            row.put("level", engine.loadedLevel?.key ?: "none")
                .put("image", photo.name)
                .put("kind", if (isPage) "page" else "scene")
                .put("text", said)
                .put("ttftMs", first?.getOrNull(0)?.toLongOrNull() ?: -1)
                .put("firstPassMs", first?.getOrNull(1)?.toLongOrNull() ?: -1)
                .put("encodeMs", first?.getOrNull(2)?.toLongOrNull() ?: -1)
                .put("promptTokens", first?.getOrNull(3)?.toIntOrNull() ?: -1)
                .put("genTokens", first?.getOrNull(4)?.toIntOrNull() ?: -1)
                .put("passes", passes.size)
                .put("passStats", passes.joinToString(";"))
                .put("totalMs", wallMs)
                .put("peakKb", peakKb())
                .put("loadMs", loadMs)
            out.appendText(row.toString() + "\n")
            Log.i(TAG, "RESULT $row")
        }
        engine.recordStats = false
    }

    private fun resized(shot: File, side: Int): File {
        val bitmap = BitmapFactory.decodeFile(shot.path, BitmapFactory.Options()) ?: return shot
        val long = max(bitmap.width, bitmap.height)
        if (long <= side) { bitmap.recycle(); return shot }
        val s = side.toFloat() / long
        val scaled = Bitmap.createScaledBitmap(bitmap, (bitmap.width * s).roundToInt(), (bitmap.height * s).roundToInt(), true)
        val out = File(shot.parentFile, shot.nameWithoutExtension + "-scene.jpg")
        out.outputStream().use { scaled.compress(Bitmap.CompressFormat.JPEG, 90, it) }
        if (scaled !== bitmap) scaled.recycle()
        bitmap.recycle()
        return out
    }

    /** Peak resident memory of this process (the app's process: the test runs inside it). */
    private fun peakKb(): Long = try {
        File("/proc/self/status").readLines().firstOrNull { it.startsWith("VmHWM:") }
            ?.replace(Regex("[^0-9]"), "")?.toLong() ?: -1
    } catch (t: Throwable) { -1 }

    private companion object { const val TAG = "PhotoSetPhoneTest" }
}
