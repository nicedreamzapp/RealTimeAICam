package com.mattmacosko.realtimeaicam.translation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Ported from the iPhone's SpanishLiteralShieldTests.swift. The word engine used
// to break numbers and names apart: "1.234,56 €" came back "1. 234, 56 €",
// "IBAN" came back "they were" (2026-09-16).
class SpanishLiteralShieldTest {
    @Test fun literalsSurviveTheRoundTrip() {
        val input = "Total 1.234,56 € a las 9:00, IBAN ES91 2100, tarjeta ****4471, Col. Juárez, C.P. 06600"
        val (shielded, held) = SpanishTranslationEngine.shieldLiterals(input)
        assertFalse(shielded, shielded.any { it.isDigit() })
        val back = SpanishTranslationEngine.restoreLiterals(shielded, held)
        assertTrue(back, back.contains("1.234,56 €"))
        assertTrue(back, back.contains("9:00"))
        assertTrue(back, back.contains("IBAN ES91 2100"))
        assertTrue(back, back.contains("****4471"))
        assertTrue(back, back.contains("Colonia Juárez"))
        assertTrue(back, back.contains("postal code 06600"))
        val (dated, dates) = SpanishTranslationEngine.shieldLiterals("Fecha: 16/09/2026")
        assertEquals("Fecha: 16 September 2026", SpanishTranslationEngine.restoreLiterals(dated, dates))
    }

    @Test fun signLinesAreTranslatedSeparately() {
        assertEquals(
            listOf("Estacionamiento \$15 por hora", "Salida 42"),
            SpanishTranslationEngine.translationUnits("Estacionamiento \$15 por hora\nSalida 42"),
        )
        assertEquals(
            listOf("El perro corre por el parque."),
            SpanishTranslationEngine.translationUnits("El perro corre por\nel parque."),
        )
    }
}
