package com.mattmacosko.realtimeaicam.aim

import com.mattmacosko.realtimeaicam.AppLang
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Help Me Aim in a Spanish app (2026-11-05): the app's own lines come from values-es, the
 * object names are content and go through [AimNames] (the translator, faked here).
 */
class HelpMeAimSpanishTest {
    private val key = AimVocabulary.Match("key", listOf("key"), listOf(0))
    private val cup = AimVocabulary.Match("cup", listOf("cup"), listOf(1))
    private val asked = ArrayList<String>()

    @Before fun spanish() {
        AppLang.testCode = "es"
        AimNames.clear()
        asked.clear()
        AimNames.translate = { text, lang ->
            asked.add(text)
            assertEquals("es", lang)
            mapOf(
                "a key" to "una llave", "key" to "la llave",
                "a dog" to "un perro", "a laptop" to "una laptop", "eyeglasses" to "los anteojos",
            )[text]
        }
    }

    @After fun english() {
        AppLang.testCode = null
        AimNames.translate = null
        AimNames.onMainThread = { false }
        AimNames.clear()
    }

    @Test fun aMainThreadCallIsNotAMissAndAMissIsNotAskedAgain() {
        // On the main thread nothing is asked and nothing is remembered...
        AimNames.onMainThread = { true }
        assertEquals("key", AimNames.bare("key"))
        assertTrue(asked.isEmpty())
        // ...so a worker right after still gets the Spanish.
        AimNames.onMainThread = { false }
        assertEquals("llave", AimNames.bare("key"))
        // A real miss (no translation) is asked once, not on every frame.
        asked.clear()
        assertEquals("umbrella", AimNames.bare("umbrella"))
        assertEquals("umbrella", AimNames.bare("umbrella"))
        assertEquals(1, asked.count { it == "umbrella" })
    }

    @Test fun steeringLinesAreSpanish() {
        assertEquals("muévelo a la izquierda", AimPhrases.phrase(AimInstruction.MOVE_LEFT, AimSubject.Face))
        assertEquals("muévelo hacia arriba", AimPhrases.phrase(AimInstruction.MOVE_UP, AimSubject.Face))
        assertEquals("listo, no te muevas", AimPhrases.phrase(AimInstruction.FRAMED, AimSubject.Face))
        assertEquals("listo, tres caras, no te muevas", AimPhrases.phrase(AimInstruction.FRAMED, AimSubject.Face, 3))
        assertEquals("aléjate, la página está cortada", AimPhrases.phrase(AimInstruction.BACK_UP_CUT_OFF, AimSubject.Page))
        assertEquals("lo perdí", AimPhrases.lostIt)
    }

    @Test fun objectNamesAreTranslatedOnceAndPutInTheSpanishSentence() {
        assertEquals(
            "Aún no veo una llave, mueve el teléfono despacio",
            AimPhrases.phrase(AimInstruction.NOT_FOUND, AimSubject.Obj(key)),
        )
        AimPhrases.intro(AimSubject.Obj(key))
        assertEquals(1, asked.count { it == "a key" })
        assertEquals("Aún no veo una llave. Gira despacio.", AimAsk.notYet("key", 1))
        // A bare name loses the article the translator adds.
        assertEquals("llave", AimNames.bare("key"))
    }

    @Test fun handFixedNamesSkipTheTranslator() {
        assertEquals("Buscando una taza. Mueve el teléfono despacio. Toca dos veces en cualquier parte para tomar la foto tú.",
            AimPhrases.intro(AimSubject.Obj(cup)))
        assertTrue(asked.isEmpty())
    }

    @Test fun whatElseIsInViewIsOneSpanishSentence() {
        assertEquals(
            "No veo una llave. Sí veo un perro, una laptop y anteojos.",
            AimElsewhere.sentence(AimSubject.Obj(key), listOf("dog", "laptop", "glasses")),
        )
    }

    @Test fun noTranslatorKeepsTheEnglishName() {
        AimNames.translate = null
        assertEquals("No veo una cara y no destaca nada más. Prueba otra dirección.",
            AimElsewhere.sentence(AimSubject.Face, emptyList()))
        assertEquals("Aún no veo a key, mueve el teléfono despacio",
            AimPhrases.phrase(AimInstruction.NOT_FOUND, AimSubject.Obj(key)))
    }

    @Test fun theCoachSpeaksSpanish() {
        val c = AimCoach(AimSubject.Face).also { it.reset(0.0) }
        val left = AimRect(0.0f, 0.25f, 0.2f, 0.2f)
        c.observe(left, now = 0.0, voiceBusy = false)
        val said = c.observe(left, now = 0.6, voiceBusy = false)
            .filterIsInstance<AimCoach.Action.Say>().map { it.text }
        assertEquals(listOf("muévelo a la izquierda"), said)
    }

    @Test fun describerLinesAreSpanishButItsQuestionStaysEnglish() {
        assertTrue(AimAsk.intro("key", 90).contains("unos 90 segundos"))
        assertEquals("Está a la izquierda. Gira el teléfono un poco a la izquierda.", AimAsk.steer(AimAsk.Place.LEFT))
        assertTrue(AimAsk.question("key").startsWith("Is there a key in this photo?"))
    }
}
