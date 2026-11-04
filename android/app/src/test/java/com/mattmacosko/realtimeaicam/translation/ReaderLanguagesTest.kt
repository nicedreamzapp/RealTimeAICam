package com.mattmacosko.realtimeaicam.translation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderLanguagesTest {
    @Test fun seventeenLanguagesPlusEnglishMatchIos() {
        assertEquals(17, ReaderLanguages.all.size)
        assertEquals(18, ReaderChoice.count)
        val labels = (0 until ReaderChoice.count).map { ReaderChoice.label(it) }
        assertEquals(
            listOf(
                "English", "Span → Eng", "French → Eng", "German → Eng", "Italian → Eng", "Port → Eng",
                "Dutch → Eng", "Polish → Eng", "Turkish → Eng", "Indo → Eng", "Viet → Eng",
                "Rus → Eng", "Ukr → Eng", "Chin → Eng", "Jpn → Eng", "Kor → Eng", "Thai → Eng", "Arab → Eng",
            ),
            labels,
        )
        val spoken = (11 until ReaderChoice.count).map { ReaderChoice.spoken(it) }
        assertEquals(
            listOf("Russian", "Ukrainian", "Chinese", "Japanese", "Korean", "Thai", "Arabic")
                .map { "$it, translated to English" },
            spoken,
        )
    }

    @Test fun newLanguagesUseGoogleTranslateCodes() {
        assertEquals(
            listOf("ru", "uk", "zh", "ja", "ko", "th", "ar"),
            ReaderLanguages.all.drop(10).map { it.code },
        )
        assertEquals(ReaderLanguages.all.size, ReaderLanguages.all.map { it.code }.toSet().size)
        assertEquals(ReaderLanguages.all.size, ReaderLanguages.all.map { it.tag }.toSet().size)
    }

    @Test fun onlyTheSevenNeedADownloadedReader() {
        ReaderLanguages.all.take(10).forEach { assertFalse(it.name, it.needsReaderDownload) }
        ReaderLanguages.all.drop(10).forEach { assertTrue(it.name, it.needsReaderDownload) }
        assertEquals(
            listOf("rus", "ukr", "tha", "ara"),
            ReaderLanguages.all.mapNotNull { it.reader.tessCode },
        )
        assertEquals(ScriptReader.CHINESE, ReaderLanguages.byCode("zh").reader)
    }

    @Test fun pillLandsOnEachNewLanguage() {
        ReaderLanguages.all.forEachIndexed { i, lang ->
            assertEquals(i + 1, ReaderChoice.indexOf(true, lang))
        }
        assertEquals(0, ReaderChoice.next(17))
    }

    @Test fun wrappedChineseLinesJoinWithoutSpaces() {
        val zh = ReaderLanguages.byCode("zh")
        assertEquals(listOf("今天天气很好。", "我们去公园"), ReaderLanguages.translationUnits(zh, "今天天气\n很好。\n我们去公园"))
    }

    @Test fun wrappedArabicLinesJoinWithSpaces() {
        val ar = ReaderLanguages.byCode("ar")
        assertEquals(listOf("مرحبا بكم في المدينة."), ReaderLanguages.translationUnits(ar, "مرحبا بكم\nفي المدينة."))
    }

    @Test fun russianKeepsTheCapitalLetterRule() {
        val ru = ReaderLanguages.byCode("ru")
        assertEquals(listOf("ВЫХОД", "Добро пожаловать в город"), ReaderLanguages.translationUnits(ru, "ВЫХОД\nДобро пожаловать\nв город"))
    }

    @Test fun downloadWordsAreTheSameAsIos() {
        assertEquals("Downloading Chinese, one time only. After that it works offline.", ReaderLanguages.downloadLine("Chinese"))
    }
}
