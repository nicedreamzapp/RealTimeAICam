package com.mattmacosko.realtimeaicam

import com.mattmacosko.realtimeaicam.ui.AppMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ShortcutFeatureTest {
    @Test
    fun shortcutIdsOpenTheirScreens() {
        assertEquals(AppMode.WhatsThis, ShortcutFeature.modeFor("whats_this"))
        assertEquals(AppMode.HelpMeAim, ShortcutFeature.modeFor("help_me_aim"))
        assertEquals(AppMode.OcrEnglish, ShortcutFeature.modeFor("read_text"))
        assertEquals(AppMode.OcrSpanish, ShortcutFeature.modeFor("translate"))
        assertEquals(AppMode.ObjectDetection, ShortcutFeature.modeFor("object_detection"))
    }

    @Test
    fun spokenNamesOpenTheSameScreens() {
        assertEquals(AppMode.WhatsThis, ShortcutFeature.modeFor("What's this?"))
        assertEquals(AppMode.WhatsThis, ShortcutFeature.modeFor("what’s this"))
        assertEquals(AppMode.WhatsThis, ShortcutFeature.modeFor("what is this"))
        assertEquals(AppMode.HelpMeAim, ShortcutFeature.modeFor("Help Me Aim"))
        assertEquals(AppMode.OcrEnglish, ShortcutFeature.modeFor("read text"))
        assertEquals(AppMode.OcrSpanish, ShortcutFeature.modeFor("Translator"))
        assertEquals(AppMode.ObjectDetection, ShortcutFeature.modeFor("object detection"))
    }

    @Test
    fun nothingOrNonsenseStaysHome() {
        assertNull(ShortcutFeature.modeFor(null))
        assertNull(ShortcutFeature.modeFor(""))
        assertNull(ShortcutFeature.modeFor("settings"))
    }
}
