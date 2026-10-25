@testable import RealTime_Ai_Cam
import Testing

// Same cases as Android's SpanishIdiomPrepassTest.kt.
struct SpanishIdiomPrepassTests {
    private func run(_ s: String) async throws -> String {
        try await SpanishIdiomPrepass.translate(s) { "[\($0)]" }
    }

    @Test func listLoads() { #expect(SpanishIdiomPrepass.idioms.count > 1000) }

    @Test func wholeSentenceIdioms() async throws {
        #expect(try await run("No hay mal que por bien no venga.") == "Every cloud has a silver lining.")
        #expect(try await run("Más vale tarde que nunca.") == "Better late than never.")
    }

    @Test func colonIsNotASplitPoint() async throws {
        #expect(try await run("Menú del día: primer plato") == "[Menú del día: primer plato]")
    }

    @Test func noIdiomPassesThroughWhole() async throws {
        #expect(try await run("Cerrado los domingos. Gracias por su visita.")
                == "[Cerrado los domingos. Gracias por su visita.]")
    }

    @Test func idiomSentenceAmongOthers() async throws {
        #expect(try await run("Llegó tarde. Más vale tarde que nunca. Nos vemos.")
                == "[Llegó tarde.] Better late than never. [Nos vemos.]")
    }

    @Test func neverPatchesSingleWords() async throws {
        #expect(try await run("El perro come") == "[El perro come]")
    }
}

// Android found the camera wraps a saying across two lines. On iPhone the
// Vision lines are joined with spaces before translation (LiveOCRViewModel), so
// a two-line sign still reaches the pre-pass as one sentence. Proven end to end:
struct WrappedIdiomTests {
    @Test func twoLineSignStillMatches() async throws {
        let image = TranslateLanguagesTests.sign("No hay mal que por bien\nno venga.")
        let text = try TranslateLanguagesTests.read(image, languages: ["es-ES", "es"])
        #expect(!text.contains("\n"))
        let out = try await SpanishIdiomPrepass.translate(text) { "[\($0)]" }
        #expect(out == "Every cloud has a silver lining.", "OCR gave: \(text)")
    }
}
