package com.mattmacosko.realtimeaicam.translation

import org.junit.Assert.assertEquals
import org.junit.Test

class ReaderChoiceTest {
    @Test fun englishIsFirstThenEveryLanguage() {
        assertEquals(ReaderLanguages.all.size + 1, ReaderChoice.count)
        assertEquals("English", ReaderChoice.label(0))
        assertEquals("Span → Eng", ReaderChoice.label(1))
        assertEquals("Spanish, translated to English", ReaderChoice.spoken(1))
    }

    @Test fun indexFollowsTheScreen() {
        assertEquals(0, ReaderChoice.indexOf(false, ReaderLanguages.all[3]))
        assertEquals(4, ReaderChoice.indexOf(true, ReaderLanguages.all[3]))
    }

    @Test fun tapWrapsBackToEnglish() {
        assertEquals(1, ReaderChoice.next(0))
        assertEquals(0, ReaderChoice.next(ReaderChoice.count - 1))
    }
}
