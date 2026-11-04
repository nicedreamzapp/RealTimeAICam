package com.mattmacosko.realtimeaicam.camera

import android.speech.tts.TextToSpeech
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SpeechChecksTest {
    @Test fun volumeZeroOnlyMattersForTheAppsOwnVoice() {
        assertTrue(SpeechChecks.volumeOff(speaksAloud = true, volume = 0))
        assertFalse(SpeechChecks.volumeOff(speaksAloud = true, volume = 5))
        assertFalse(SpeechChecks.volumeOff(speaksAloud = false, volume = 0)) // TalkBack speaks instead
        assertFalse(SpeechChecks.volumeOff(speaksAloud = true, volume = null)) // unknown: no false alarm
    }

    @Test fun setLanguageResults() {
        assertTrue(SpeechChecks.languageUsable(TextToSpeech.LANG_AVAILABLE))
        assertTrue(SpeechChecks.languageUsable(TextToSpeech.LANG_COUNTRY_AVAILABLE))
        assertTrue(SpeechChecks.languageUsable(TextToSpeech.LANG_COUNTRY_VAR_AVAILABLE))
        assertFalse(SpeechChecks.languageUsable(TextToSpeech.LANG_MISSING_DATA))
        assertFalse(SpeechChecks.languageUsable(TextToSpeech.LANG_NOT_SUPPORTED))
    }

    @Test fun missingVoiceError() {
        assertTrue(SpeechChecks.meansNoVoice(TextToSpeech.ERROR_NOT_INSTALLED_YET))
        assertFalse(SpeechChecks.meansNoVoice(TextToSpeech.ERROR_OUTPUT))
    }

    @Test fun problemPriority() {
        assertNull(SpeechChecks.problem(speaksAloud = true, engineFailed = false, voiceFailed = false, volumeOff = false))
        assertEquals(SpeechProblem.NO_ENGINE, SpeechChecks.problem(true, engineFailed = true, voiceFailed = true, volumeOff = true))
        assertEquals(SpeechProblem.NO_VOICE, SpeechChecks.problem(true, engineFailed = false, voiceFailed = true, volumeOff = true))
        assertEquals(SpeechProblem.VOLUME_OFF, SpeechChecks.problem(true, engineFailed = false, voiceFailed = false, volumeOff = true))
        // App voice switched off: TalkBack does the talking, so none of these apply.
        assertNull(SpeechChecks.problem(false, engineFailed = true, voiceFailed = true, volumeOff = true))
    }
}
