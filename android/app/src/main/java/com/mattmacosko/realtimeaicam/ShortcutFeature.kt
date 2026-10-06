package com.mattmacosko.realtimeaicam

import com.mattmacosko.realtimeaicam.ui.AppMode

/**
 * Google Assistant, Gemini and the home-screen long-press menu can open the app straight
 * into a camera screen, the same five the iPhone's Siri shortcuts open (Matt, 2026-09-22).
 * They arrive as an intent extra: a shortcut sends its id, the assistant sends whatever
 * words it heard for the feature, so both are matched here.
 */
object ShortcutFeature {
    const val EXTRA = "feature"

    fun modeFor(feature: String?): AppMode? {
        val words = feature
            ?.lowercase()
            ?.replace("’", "'")
            ?.replace("'", "")
            ?.replace(Regex("[^a-z ]"), " ")
            ?.replace(Regex("\\s+"), " ")
            ?.trim()
            ?: return null
        if (words.isEmpty()) return null
        return when {
            words == "whats this" || words == "what is this" || "describe" in words
                || "in front of me" in words -> AppMode.WhatsThis
            "aim" in words || "picture" in words || "photo" in words -> AppMode.HelpMeAim
            "translat" in words -> AppMode.OcrSpanish
            "read" in words || "text" in words -> AppMode.OcrEnglish
            "object" in words || "detect" in words || "around me" in words -> AppMode.ObjectDetection
            else -> when (feature) {
                "whats_this" -> AppMode.WhatsThis
                "help_me_aim" -> AppMode.HelpMeAim
                "read_text" -> AppMode.OcrEnglish
                "translate" -> AppMode.OcrSpanish
                "object_detection" -> AppMode.ObjectDetection
                else -> null
            }
        }
    }
}
