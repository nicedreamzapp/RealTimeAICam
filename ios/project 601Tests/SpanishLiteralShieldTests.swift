@testable import RealTime_Ai_Cam
import Testing

// Same cases as Android's SpanishLiteralShieldTest.kt. The word engine used to
// break numbers and names apart: "1.234,56 €" came back "1. 234, 56 €", "IBAN"
// came back "they were" (2026-09-16). The numbers have to reach the speech
// rules exactly as printed.
struct SpanishLiteralShieldTests {
    @Test func literalsSurviveTheRoundTrip() {
        let input = "Total 1.234,56 € a las 9:00, IBAN ES91 2100, tarjeta ****4471, Col. Juárez, C.P. 06600"
        let (shielded, held) = FixedSpanishEngine.shieldLiterals(input)
        #expect(!shielded.contains { $0.isNumber })
        let back = FixedSpanishEngine.restoreLiterals(shielded, held)
        #expect(back.contains("1.234,56 €"))
        #expect(back.contains("9:00"))
        #expect(back.contains("IBAN ES91 2100"))
        #expect(back.contains("****4471"))
        #expect(back.contains("Colonia Juárez"))
        #expect(back.contains("postal code 06600"))
        let (dated, dates) = FixedSpanishEngine.shieldLiterals("Fecha: 16/09/2026")
        #expect(FixedSpanishEngine.restoreLiterals(dated, dates) == "Fecha: 16 September 2026")
    }

    // What the person hears after translation: the shielded amount comes back
    // as printed, then the speech rules read it the American way.
    @Test func restoredAmountsReadRight() {
        let (shielded, held) = FixedSpanishEngine.shieldLiterals("Total 1.234,56 €")
        let back = FixedSpanishEngine.restoreLiterals(shielded, held)
        #expect(SpeakableText.make(back) == "Total 1,234.56 €")
    }
}
