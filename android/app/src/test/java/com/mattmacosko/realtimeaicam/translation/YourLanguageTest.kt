package com.mattmacosko.realtimeaicam.translation

import com.mattmacosko.realtimeaicam.aim.AimInput
import com.mattmacosko.realtimeaicam.aim.AimVocabulary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Your language (2026-11-04). Same cases as iOS YourLanguageTests.swift. */
class YourLanguageTest {
    @Test fun eighteenChoicesEnglishFirst() {
        assertEquals(18, YourLanguageRules.codes.size)
        assertEquals("en", YourLanguageRules.codes.first())
        assertTrue(YourLanguageRules.codes.containsAll(listOf("es", "fr", "de", "ru", "zh", "ja", "ko", "th", "ar", "id", "vi")))
    }

    @Test fun defaultFollowsThePhoneWhenSupported() {
        assertEquals("es", YourLanguageRules.defaultFor("es"))
        assertEquals("fr", YourLanguageRules.defaultFor("fr-CA"))
        assertEquals("id", YourLanguageRules.defaultFor("in")) // Java's old code for Indonesian
        assertEquals("zh", YourLanguageRules.defaultFor("zh_TW"))
        assertEquals("en", YourLanguageRules.defaultFor("en"))
        assertEquals("en", YourLanguageRules.defaultFor("sw")) // not supported -> English
        assertEquals("en", YourLanguageRules.defaultFor("he"))
    }

    @Test fun savedChoiceWins() {
        assertEquals("en", YourLanguageRules.resolve("en", "es"))
        assertEquals("fr", YourLanguageRules.resolve("fr", "en"))
        assertEquals("es", YourLanguageRules.resolve(null, "es"))
        assertEquals("es", YourLanguageRules.resolve("xx", "es")) // junk saved value
    }

    @Test fun firstLaunchAnnouncedOnlyForSupportedNonEnglishOnce() {
        assertTrue(YourLanguageRules.shouldAnnounceFirstLaunch("es", false))
        assertFalse(YourLanguageRules.shouldAnnounceFirstLaunch("es", true))
        assertFalse(YourLanguageRules.shouldAnnounceFirstLaunch("en", false))
        assertFalse(YourLanguageRules.shouldAnnounceFirstLaunch("sw", false))
        assertEquals(
            "Your language is French. Spoken results can be translated into French after a one-time download. You can change this in Settings.",
            YourLanguageRules.firstLaunchLine("fr"),
        )
    }

    @Test fun downloadRowWording() {
        assertEquals("Download Spanish once, then it works offline", YourLanguageRules.downloadRow("es"))
        assertEquals("No French voice is installed on this phone. You can add one in the phone's speech settings.",
            YourLanguageRules.noVoiceLine("fr"))
    }

    @Test fun pillUnchangedForEnglish() {
        assertEquals("English", YourLanguageRules.pillLabel(null, "en"))
        assertEquals("French → Eng", YourLanguageRules.pillLabel(ReaderLanguages.byCode("fr"), "en"))
        assertEquals("Span → Eng", YourLanguageRules.pillLabel(ReaderLanguages.spanish, "en"))
        // Same as the old ReaderChoice labels.
        for (i in 0 until ReaderChoice.count) {
            val page = if (i == 0) null else ReaderLanguages.all[i - 1]
            assertEquals(ReaderChoice.label(i), YourLanguageRules.pillLabel(page, "en"))
            assertEquals(ReaderChoice.spoken(i), YourLanguageRules.pillSpoken(page, "en"))
        }
    }

    @Test fun pillNamesBothEndsForYourLanguage() {
        assertEquals("French → Spanish", YourLanguageRules.pillLabel(ReaderLanguages.byCode("fr"), "es"))
        assertEquals("English → Spanish", YourLanguageRules.pillLabel(null, "es"))
        assertEquals("Spanish", YourLanguageRules.pillLabel(ReaderLanguages.spanish, "es"))
        assertEquals("English, translated to French", YourLanguageRules.pillSpoken(null, "fr"))
    }

    // ---- What's this? ----

    private val fake = { t: String, from: String, to: String ->
        when ("$from>$to:$t") {
            "en>es:A red mug on a table." -> "Una taza roja sobre una mesa."
            "es>en:¿De qué color es?" -> "What color is it?"
            else -> null
        }
    }

    @Test fun answerTranslatedIntoYourLanguage() {
        assertEquals("Una taza roja sobre una mesa." to "es", AnswerLanguage.forPerson("A red mug on a table.", "es", fake))
    }

    @Test fun answerStaysEnglishForEnglishOrWhenTranslationFails() {
        assertEquals("A red mug on a table." to "en", AnswerLanguage.forPerson("A red mug on a table.", "en", fake))
        assertEquals("Something else." to "en", AnswerLanguage.forPerson("Something else.", "es", fake))
    }

    @Test fun followUpQuestionGoesToTheModelInEnglish() {
        assertEquals("What color is it?", AnswerLanguage.questionForModel("¿De qué color es?", "es", fake))
        assertEquals("What color is it?", AnswerLanguage.questionForModel("What color is it?", "en", fake))
        assertEquals("¿Qué?", AnswerLanguage.questionForModel("¿Qué?", "es", fake)) // no translation: as said
    }

    // ---- Help Me Aim ----

    @Test fun spanishTargetWordMapsToCup() {
        val classes = File("src/main/assets/class_names.txt").readLines().filter { it.isNotBlank() }
        val english = AimInput.toEnglish("taza", "es") { w, from -> if (w == "taza" && from == "es") "Cup." else null }
        assertEquals("Cup", english)
        val m = AimVocabulary.match(english, classes)
        assertNotNull(m)
        assertTrue(m!!.classNames.any { it == "mug" || it == "coffee cup" })
    }

    @Test fun aimInputKeepsTheWordWhenItCantTranslate() {
        assertEquals("taza", AimInput.toEnglish(" taza ", "es") { _, _ -> null })
        assertEquals("cup", AimInput.toEnglish("cup", "en") { _, _ -> "never" })
    }
}
