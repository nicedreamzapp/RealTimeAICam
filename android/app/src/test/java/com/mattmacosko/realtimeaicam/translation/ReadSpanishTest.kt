package com.mattmacosko.realtimeaicam.translation

import com.mattmacosko.realtimeaicam.AppLang
import com.mattmacosko.realtimeaicam.R
import com.mattmacosko.realtimeaicam.camera.ReadingMode
import com.mattmacosko.realtimeaicam.ui.OcrCardSemantics
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

/** Read and What's this? in a Spanish app (2026-11-05): names, pill, lines and the countdown. */
class ReadSpanishTest {
    @After fun reset() { AppLang.testCode = null }

    private val french get() = ReaderLanguages.byCode("fr")

    @Test fun englishAppKeepsTheEnglishPill() {
        AppLang.testCode = "en"
        for (i in 0 until ReaderChoice.count) {
            val page = if (i > 0) ReaderLanguages.all[i - 1] else null
            for (target in listOf("en", "es", "fr")) {
                assertEquals(YourLanguageRules.pillLabel(page, target), ReaderChoice.pillLabel(page, target))
                assertEquals(YourLanguageRules.pillSpoken(page, target), ReaderChoice.pillSpoken(page, target))
            }
        }
        assertEquals("Language, English", OcrCardSemantics.languageLabel("English"))
    }

    @Test fun spanishAppNamesTheLanguagesInSpanish() {
        AppLang.testCode = "es"
        assertEquals("Inglés", ReaderChoice.pillLabel(null, "en"))
        assertEquals("Francés → Ing", ReaderChoice.pillLabel(french, "en"))
        assertEquals("Francés, traducido al inglés", ReaderChoice.pillSpoken(french, "en"))
        assertEquals("Francés → Español", ReaderChoice.pillLabel(french, "es"))
        assertEquals("Francés, traducido al español", ReaderChoice.pillSpoken(french, "es"))
        assertEquals("Inglés → Español", ReaderChoice.pillLabel(null, "es"))
        assertEquals("Español", ReaderChoice.pillLabel(ReaderLanguages.spanish, "es"))
        assertEquals("Español", ReaderChoice.pillSpoken(ReaderLanguages.spanish, "es"))
        assertEquals("Idioma, Inglés", OcrCardSemantics.languageLabel(ReaderChoice.pillSpoken(null, "en")))
        assertEquals("árabe", ReaderLanguages.byCode("ar").nameInSentence)
    }

    @Test fun everyReaderLanguageHasASpanishName() {
        AppLang.testCode = "es"
        val names = ReaderLanguages.all.map { it.displayName }
        assertEquals(names.size, names.toSet().size)
        ReaderLanguages.all.forEach { assert(it.displayName != it.name || it.name == "Thai") { it.code } }
    }

    @Test fun readerLinesAreInTheAppLanguage() {
        AppLang.testCode = "es"
        val zh = ReaderLanguages.byCode("zh")
        assertEquals("Descargando chino, solo esta vez. Después funciona sin internet.", ReaderLanguages.downloadLine(zh.nameInSentence))
        assertEquals("Chino está listo. Apunta al texto.", ReaderLanguages.readyLine(zh.displayName))
        AppLang.testCode = "en"
        assertEquals("Chinese is ready. Point at the text.", ReaderLanguages.readyLine(zh.displayName))
    }

    @Test fun readingModesAndCountdownFollowTheAppLanguage() {
        AppLang.testCode = "es"
        assertEquals("Lectura automática", ReadingMode.AUTO.label)
        assertEquals(listOf("tres", "dos", "uno"),
            listOf(R.string.f_count_three, R.string.f_count_two, R.string.f_count_one).map { AppLang.str(it) })
        AppLang.testCode = "en"
        assertEquals("Auto read", ReadingMode.AUTO.label)
        assertEquals("three", AppLang.str(R.string.f_count_three))
    }
}
