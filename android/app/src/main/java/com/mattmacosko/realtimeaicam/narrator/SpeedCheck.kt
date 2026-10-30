package com.mattmacosko.realtimeaicam.narrator

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Settings > Models > "Check this phone's speed again": one bundled photo (CC0,
 * exit doors) on Balanced, timed inside the model. Blocking; call off the main
 * thread. The first real What's this? photo does the same job automatically.
 */
object SpeedCheck {
    fun run(context: Context): Double? = try {
        val photo = File(context.cacheDir, "speedcheck.jpg")
        if (!photo.isFile) context.assets.open("speedcheck.jpg").use { i -> photo.outputStream().use { i.copyTo(it) } }
        val engine = NarratorEngine.get(context)
        engine.select(ModelLevel.BALANCED)
        val said = engine.describe(photo, NarratorPrompt.SCENE_QUESTION)
        val seconds = engine.lastPassSeconds
        Log.i("SpeedCheck", "balanced answered in $seconds s: $said")
        if (said.isBlank() || seconds <= 0) null else seconds.also {
            ModelPicker.setBalancedSeconds(context, it)
            ModelDownloader.fetchWanted(context, automatic = true)
        }
    } catch (t: Throwable) {
        Log.e("SpeedCheck", "failed", t)
        null
    }
}
