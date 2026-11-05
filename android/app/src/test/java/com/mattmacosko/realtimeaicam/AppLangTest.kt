package com.mattmacosko.realtimeaicam

import org.junit.Assert.assertEquals
import org.junit.Test

class AppLangTest {
    @Test fun spanishPhoneIsSpanish() {
        assertEquals("es", AppLang.uiCode("es", "en"))
        assertEquals("es", AppLang.uiCode("es", "fr"))
    }

    @Test fun yourLanguageSpanishOnAnEnglishPhoneIsSpanish() {
        assertEquals("es", AppLang.uiCode("en", "es"))
    }

    @Test fun everythingElseIsEnglish() {
        assertEquals("en", AppLang.uiCode("en", "en"))
        assertEquals("en", AppLang.uiCode("fr", "fr"))
        assertEquals("en", AppLang.uiCode(null, "de"))
    }

    @Test fun unitTestsReadTheSourceStrings() {
        AppLang.testCode = "en"
        try {
            assertEquals("RealTime AI Cam", AppLang.str(R.string.app_name))
        } finally {
            AppLang.testCode = null
        }
    }
}
