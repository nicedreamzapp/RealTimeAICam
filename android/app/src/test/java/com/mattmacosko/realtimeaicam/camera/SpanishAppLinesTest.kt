package com.mattmacosko.realtimeaicam.camera

import com.mattmacosko.realtimeaicam.AppLang
import com.mattmacosko.realtimeaicam.narrator.ModelLevel
import com.mattmacosko.realtimeaicam.narrator.ModelPicker
import com.mattmacosko.realtimeaicam.translation.ReaderLanguages
import com.mattmacosko.realtimeaicam.translation.YourLanguageRules
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Spanish UI (2026-11-05): the app's own lines in Spanish, and each line in a voice for its language. */
class SpanishAppLinesTest {
    @After fun reset() { AppLang.testCode = null }

    @Test fun cuesFollowTheAppLanguage() {
        AppLang.testCode = "es"
        assertEquals("Inicio", UiCue.HOME)
        assertEquals("Apunta la cámara a un texto", UiCue.READ_HINT)
        assertEquals("Live Cam llegará pronto.", UiCue.LIVE_CAM_COMING_SOON)
        assertEquals("El volumen está apagado. Súbelo para escuchar la app.", SpeechChecks.volumeOffLine())
        AppLang.testCode = "en"
        assertEquals("Volume is off. Turn it up to hear the app.", SpeechChecks.volumeOffLine())
    }

    @Test fun languageNamesInTheAppLanguage() {
        AppLang.testCode = "es"
        assertEquals("Español", YourLanguageRules.name("es"))
        assertEquals("Francés", YourLanguageRules.name("fr"))
        assertEquals("francés", YourLanguageRules.nameInSentence("fr"))
        assertEquals("Descarga francés una vez y luego funciona sin internet", YourLanguageRules.downloadRow("fr"))
        assertEquals("Francés → Español", YourLanguageRules.pillLabel(ReaderLanguages.byCode("fr"), "es"))
        assertEquals("Francés → Ing", YourLanguageRules.pillLabel(ReaderLanguages.byCode("fr"), "en"))
        assertEquals("Inglés, traducido al francés", YourLanguageRules.pillSpoken(null, "fr"))
        // Read by the English voice, so it stays English.
        assertTrue(YourLanguageRules.noVoiceLine("fr").startsWith("No French voice"))
        assertEquals("Este teléfono no tiene una voz en francés. Puedes agregar una en la configuración de voz del teléfono.",
            YourLanguageRules.noVoiceShown("fr"))
        assertTrue(YourLanguageRules.guide().contains("están en español"))
    }

    @Test fun englishGuideNoLongerSaysButtonsStayEnglish() {
        AppLang.testCode = "en"
        assertFalse(YourLanguageRules.guide().contains("Buttons stay in English"))
        assertTrue(YourLanguageRules.guide().contains("Buttons, menus and this guide are in Spanish"))
    }

    @Test fun modelWordsInSpanish() {
        AppLang.testCode = "es"
        assertEquals("Nítido", ModelLevel.SHARP.title)
        assertEquals("alrededor de 12 segundos", ModelPicker.spoken(12.0))
        AppLang.testCode = "en"
        assertEquals("Sharp", ModelLevel.SHARP.title)
        assertEquals("about 12 seconds", ModelPicker.spoken(12.0))
        assertEquals("about a minute", ModelPicker.spoken(70.0))
    }

    @Test fun aVoiceSaysOnlyItsOwnLanguage() {
        assertTrue(SpeechVoices.speaks("es", "es"))
        assertTrue(SpeechVoices.speaks("en", "en"))
        assertFalse(SpeechVoices.speaks("en", "es"))
        assertFalse(SpeechVoices.speaks("es", "en"))
        assertTrue(SpeechVoices.speaks("in", "id")) // Java's old Indonesian code
        assertFalse(SpeechVoices.speaks(null, "es"))
    }

    @Test fun everyGroupEStringHasSpanish() {
        val roots = listOf("src/main/res", "app/src/main/res", "android/app/src/main/res").map { java.io.File(it) }
        val res = roots.first { it.isDirectory }
        val name = Regex("""<(?:string|plurals)\s+name="(e_[^"]+)"""")
        fun names(dir: String) = name.findAll(java.io.File(res, "$dir/strings_e.xml").readText()).map { it.groupValues[1] }.toSet()
        assertEquals(names("values"), names("values-es"))
    }
}
