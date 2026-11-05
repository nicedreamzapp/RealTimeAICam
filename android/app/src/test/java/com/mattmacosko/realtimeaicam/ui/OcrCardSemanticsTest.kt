package com.mattmacosko.realtimeaicam.ui

import com.mattmacosko.realtimeaicam.translation.ReaderChoice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** Read's text card and language pill as TalkBack hears them (2026-11-04). */
class OcrCardSemanticsTest {
    @Test fun cardSaysTheTextOnce() {
        val letter = "Humboldt County Water District. Dear Customer"
        val label = OcrCardSemantics.label("Detected", letter)
        assertEquals("Detected. $letter", label)
        assertEquals(1, Regex(Regex.escape(letter)).findAll(label).count())
    }

    @Test fun emptyCardIsJustItsHeading() {
        assertEquals("Language pack", OcrCardSemantics.label("Language pack", " "))
    }

    @Test fun languagePillIsNamedNotASlider() {
        val label = OcrCardSemantics.languageLabel("English")
        assertEquals("Language, English", label)
        assertFalse(label.contains("slider", ignoreCase = true))
    }

    @Test fun previousLanguageWrapsFromEnglishToTheLast() {
        assertEquals(ReaderChoice.count - 1, ReaderChoice.previous(0))
        assertEquals(0, ReaderChoice.previous(1))
        assertEquals(0, ReaderChoice.next(ReaderChoice.previous(0)))
    }
}
