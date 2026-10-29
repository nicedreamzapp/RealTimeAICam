package com.mattmacosko.realtimeaicam.translation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import java.io.File

// Same cases as the iPhone's SpanishIdiomPrepass checks (2026-10-23). The translator is
// stubbed as identity-with-brackets, so anything in [ ] went to Google's translator.
class SpanishIdiomPrepassTest {
    companion object {
        @BeforeClass @JvmStatic fun loadIdioms() {
            // Unit tests run from the module folder (app/).
            val f = listOf("src/main/assets/es_idioms.json", "app/src/main/assets/es_idioms.json")
                .map(::File).first { it.exists() }
            SpanishIdiomPrepass.load { f.inputStream() }
        }
    }

    private val calls = ArrayList<String>()
    private fun run(text: String) = SpanishIdiomPrepass.translate(text) { calls.add(it); "[$it]" }

    @Test fun shippedListLoads() {
        assertEquals(1322, SpanishIdiomPrepass.size)
    }

    @Test fun wholeSentenceIdiom() {
        assertEquals("Every cloud has a silver lining.", run("No hay mal que por bien no venga."))
        assertTrue(calls.isEmpty())
    }

    @Test fun accentedIdiom() {
        assertEquals("Better late than never.", run("Más vale tarde que nunca."))
        assertTrue(calls.isEmpty())
    }

    @Test fun colonIsNotASplitPoint() {
        assertEquals("[Menú del día: primer plato]", run("Menú del día: primer plato"))
        assertEquals(listOf("Menú del día: primer plato"), calls)
    }

    @Test fun sentenceWithNoIdiomPassesThroughWhole() {
        assertEquals("[Cerrado los domingos.]", run("Cerrado los domingos."))
        assertEquals(listOf("Cerrado los domingos."), calls)
    }

    @Test fun neighbouringTranslatorPiecesStayTogether() {
        assertEquals(
            "[Cerrado los domingos.\nGracias por su visita.]",
            run("Cerrado los domingos.\nGracias por su visita."),
        )
        assertEquals(1, calls.size)
    }

    @Test fun idiomClauseIsReplacedAndTheRestTranslated() {
        assertEquals("[Bueno,] better late than never.", run("Bueno, más vale tarde que nunca."))
        assertEquals(listOf("Bueno,"), calls)
    }

    @Test fun idiomWrappedByTheReaderStillMatches() {
        // What the app feeds the prepass: the sign-line units, wrapped lines re-joined.
        val units = SpanishTranslationEngine.translationUnits("No hay mal que por\nbien no venga.")
        assertEquals("Every cloud has a silver lining.", run(units.joinToString("\n")))
        assertTrue(calls.isEmpty())
    }

    @Test fun singleWordsAreNeverPatched() {
        assertEquals("", SpanishIdiomPrepass.normalize("¿!"))
        assertEquals("mas vale tarde que nunca", SpanishIdiomPrepass.normalize("¡Más  vale, tarde que nunca!"))
        assertEquals("[Hola.]", run("Hola."))
    }
}
