import Foundation
import Testing
@testable import RealTime_Ai_Cam

/// Help Me Aim in Spanish (2026-11-05): its own lines come from the bundled
/// Spanish, never the translator; names inside them are the person's words.
struct HelpMeAimSpanishTests {
    @Test func spanishAppSaysTheBundledLine() {
        #expect(AimLineRoute.pick(appLang: "es", yourLanguage: "es") == .asIs("es"))
        // Spanish phone, Your language English or French: still the bundled Spanish.
        #expect(AimLineRoute.pick(appLang: "es", yourLanguage: "en") == .asIs("es"))
        #expect(AimLineRoute.pick(appLang: "es", yourLanguage: "fr") == .asIs("es"))
        // English app: English as before, other languages through the translator.
        #expect(AimLineRoute.pick(appLang: "en", yourLanguage: "en") == .asIs("en"))
        #expect(AimLineRoute.pick(appLang: "en", yourLanguage: "fr") == .translate)
    }

    @Test func steeringLinesAreInTheCatalog() {
        for key in ["move the phone left", "move the phone right", "move the phone up", "move the phone down",
                    "move closer", "back up", "got it, hold still", "lost it",
                    "After the beep, say what you're looking for."] {
            #expect(AppLang.hasSpanish(key), "\(key)")
        }
        #expect(AppLang.text("move the phone left", in: "es") == "muévelo a la izquierda")
        #expect(AppLang.text("got it, hold still", in: "es") == "listo, no te muevas")
        // Short: the steering lines repeat while aiming.
        #expect(AppLang.text("move the phone right", in: "es").count <= 24)
    }

    @Test func namesKeepSpanishWordOrder() {
        let es = AppLang.text("I don't see %@ yet, move the phone slowly", in: "es")
        #expect(String(format: es, "mis llaves") == "Aún no veo mis llaves, mueve el teléfono despacio")
        let list = String(format: AppLang.text("%@ and %@", in: "es"), "una laptop, un perro", "una taza")
        #expect(String(format: AppLang.text("I don't see %@. I can see %@.", in: "es"), "mis llaves", list)
            == "No veo mis llaves. Sí veo una laptop, un perro y una taza.")
    }

    @Test func thePersonsOwnWordsNameTheThing() {
        #expect(AimNames.spanishPhrase("Busco mis llaves.") == "mis llaves")
        #expect(AimNames.spanishPhrase("¿Dónde está la taza?") == "la taza")
        #expect(AimNames.spanishPhrase("cartera") == "cartera")
        AimNames.setSpanish("zzkey", "mis llaves")
        #expect(AimNames.withArticle("zzkey", lang: "es") == "mis llaves")
        #expect(AimNames.bare("zzkey", lang: "es") == "llaves")
        #expect(AimNames.withoutArticle("una laptop") == "laptop")
        #expect(AimNames.withoutArticle("taza") == "taza")
        // English stays exactly as before.
        #expect(AimNames.withArticle("zzkey", lang: "en") == "a zzkey")
        #expect(AimNames.bare("zzkey", lang: "en") == "zzkey")
        // Nothing known yet: the bare English word, never a gap.
        #expect(AimNames.withArticle("zzlaptop", lang: "es") == "zzlaptop")
    }

    @Test func faceCountIsADigitInSpanish() {
        #expect(AimPhrases.countWord(2, lang: "es") == "2")
        #expect(AimPhrases.countWord(2, lang: "en") == "two")
    }
}
