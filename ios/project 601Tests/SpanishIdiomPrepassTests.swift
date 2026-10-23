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
