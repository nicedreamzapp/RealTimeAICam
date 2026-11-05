package com.mattmacosko.realtimeaicam.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** First-time-user test, 2026-11-04: each screen cue is said once, by one voice. */
class UiCueTest {
    @Test fun talkBackOnMeansTalkBackOnly() {
        assertEquals(UiCue.Route.SCREEN_READER, UiCue.route(screenReaderOn = true))
    }

    @Test fun talkBackOffMeansTheAppVoice() {
        assertEquals(UiCue.Route.APP_VOICE, UiCue.route(screenReaderOn = false))
    }

    @Test fun readHintWhenNothingIsThereYet() {
        assertTrue(UiCue.shouldSayReadHint(hasText = false, speaking = false, openedByLanguagePill = false))
    }

    @Test fun noReadHintOverTextAlreadyFound() {
        assertFalse(UiCue.shouldSayReadHint(hasText = true, speaking = false, openedByLanguagePill = false))
    }

    @Test fun noReadHintWhileReading() {
        assertFalse(UiCue.shouldSayReadHint(hasText = false, speaking = true, openedByLanguagePill = false))
    }

    @Test fun noReadHintAfterTheLanguagePillSwitchedReaders() {
        assertFalse(UiCue.shouldSayReadHint(hasText = false, speaking = false, openedByLanguagePill = true))
    }

    @Test fun cueWordsStayShort() {
        assertEquals("Home", UiCue.HOME)
        assertEquals("Point the camera at some text", UiCue.READ_HINT)
        assertEquals("Live Cam is coming soon.", UiCue.LIVE_CAM_COMING_SOON)
    }
}
