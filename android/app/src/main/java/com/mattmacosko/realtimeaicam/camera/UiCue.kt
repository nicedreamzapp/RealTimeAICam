package com.mattmacosko.realtimeaicam.camera

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.view.accessibility.AccessibilityManager

/**
 * Short screen cues ("Home", "Point the camera at some text", "Live Cam is coming soon."), from
 * the first-time-user tests of 2026-11-04. Each is said ONCE: TalkBack announces it when TalkBack
 * is on, the app's own voice says it when it is off. Through both it was heard twice, two voices
 * over each other.
 */
object UiCue {
    const val HOME = "Home"
    const val READ_HINT = "Point the camera at some text"
    const val LIVE_CAM_COMING_SOON = "Live Cam is coming soon."

    /** How long Read waits after opening before its hint, so text found right away wins. */
    const val READ_HINT_DELAY_MS = 1_200L
    /** After "Home", the pause before TalkBack's focus moves to Settings (which cuts speech off). */
    const val HOME_FOCUS_DELAY_MS = 900L

    enum class Route { SCREEN_READER, APP_VOICE }

    fun route(screenReaderOn: Boolean): Route = if (screenReaderOn) Route.SCREEN_READER else Route.APP_VOICE

    /**
     * TalkBack (or another screen reader) is running: explore by touch is on, or an enabled
     * service gives spoken feedback (TalkBack with explore by touch off still speaks).
     */
    fun screenReaderOn(context: Context): Boolean {
        val am = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
        if (am == null || !am.isEnabled) return false
        if (am.isTouchExplorationEnabled) return true
        return try {
            am.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_SPOKEN).isNotEmpty()
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Read's opening hint: only when nothing is shown or being read yet, and not when the screen
     * opened because the language pill switched readers (that choice was just said instead).
     */
    fun shouldSayReadHint(hasText: Boolean, speaking: Boolean, openedByLanguagePill: Boolean): Boolean =
        !hasText && !speaking && !openedByLanguagePill
}
