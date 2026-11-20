package com.mattmacosko.realtimeaicam

import android.content.Context
import android.content.SharedPreferences

/**
 * Tracks translation usage and triggers a rating prompt after enough translations.
 * Mirrors the iOS RatingTracker.
 */
object RatingTracker {

    private const val PREFS_NAME = "rtcam"
    private const val KEY_COUNT = "ratingTranslationCount"
    private const val KEY_DISMISSED_FOREVER = "ratingPromptDismissedForever"
    private const val KEY_LAST_SHOWN_VERSION = "ratingPromptLastShownVersion"
    private const val THRESHOLD = 10

    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    fun recordTranslation(context: Context) {
        if (!::prefs.isInitialized) {
            prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        }
        var count = prefs.getInt(KEY_COUNT, 0) + 1
        prefs.edit().putInt(KEY_COUNT, count).apply()

        if (shouldShow(count)) {
            showPrompt(context)
        }
    }

    fun reset() {
        if (::prefs.isInitialized) {
            prefs.edit().remove(KEY_COUNT).apply()
        }
    }

    fun shouldShowPrompt(): Boolean {
        if (!::prefs.isInitialized) return false
        if (prefs.getBoolean(KEY_DISMISSED_FOREVER, false)) return false
        val currentVersion = currentVersion()
        val lastShown = prefs.getString(KEY_LAST_SHOWN_VERSION, "")
        if (lastShown == currentVersion) return false
        return prefs.getInt(KEY_COUNT, 0) >= THRESHOLD
    }

    fun dismissForever() {
        if (::prefs.isInitialized) {
            prefs.edit().putBoolean(KEY_DISMISSED_FOREVER, true).apply()
        }
    }

    fun markShown() {
        if (::prefs.isInitialized) {
            prefs.edit().putString(KEY_LAST_SHOWN_VERSION, currentVersion()).apply()
        }
    }

    private fun shouldShow(count: Int): Boolean {
        if (prefs.getBoolean(KEY_DISMISSED_FOREVER, false)) return false
        val currentVersion = currentVersion()
        val lastShown = prefs.getString(KEY_LAST_SHOWN_VERSION, "")
        if (lastShown == currentVersion) return false
        return count >= THRESHOLD
    }

    private fun showPrompt(context: Context) {
        markShown()
        // Post a broadcast that the Activity can catch
        val intent = android.content.Intent("com.mattmacosko.realtimeaicam.RATING_PROMPT_SHOW")
        intent.setPackage(context.packageName)
        context.sendBroadcast(intent)
    }

    private fun currentVersion(): String {
        return try {
            val pm = if (::prefs.isInitialized) prefs.context.packageManager else null
                ?: return "0"
            val info = pm.getPackageInfo(prefs.context.packageName, 0)
            info.versionName ?: "0"
        } catch (_: Exception) {
            "0"
        }
    }
}
