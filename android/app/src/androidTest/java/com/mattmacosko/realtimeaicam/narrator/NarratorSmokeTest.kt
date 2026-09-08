package com.mattmacosko.realtimeaicam.narrator

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Runs the real model against real photos on a real Android runtime: model load,
 * JNI, mtmd image encode, decode, detokenise. The camera is not involved — this
 * is here to prove the engine works before anyone ships it.
 *
 * Photos are pushed into the app's own files/narrator-test/ beforehand;
 * /sdcard is off limits under scoped storage.
 */
@RunWith(AndroidJUnit4::class)
class NarratorSmokeTest {

    @Test
    fun answersTestPhotos() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val engine = NarratorEngine.get(context)

        val loadStart = System.currentTimeMillis()
        val loaded = engine.ensureLoaded()
        Log.i(TAG, "model load: ${System.currentTimeMillis() - loadStart} ms, ok=$loaded")
        assertTrue("model failed to load", loaded)

        val dir = File(context.filesDir, "narrator-test")
        val photos = dir.listFiles { f -> f.name.endsWith(".jpg") }?.sortedBy { it.name }
        assertTrue("no test photos at $dir", !photos.isNullOrEmpty())

        for (photo in photos!!) {
            val question = if (photo.name.startsWith("scene")) {
                NarratorPrompt.SCENE_QUESTION
            } else {
                NarratorPrompt.PAGE_QUESTION
            }
            val start = System.currentTimeMillis()
            val said = engine.describe(photo, question)
            val ms = System.currentTimeMillis() - start
            Log.i(TAG, "RESULT ${photo.name} (${ms} ms): $said")
            assertTrue("empty answer for ${photo.name}", said.isNotBlank())
        }
    }

    private companion object { const val TAG = "NarratorSmokeTest" }
}
