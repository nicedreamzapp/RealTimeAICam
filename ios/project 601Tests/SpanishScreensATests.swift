import AVFoundation
import XCTest
@testable import RealTime_Ai_Cam

/// Spanish home, guide, Settings and Object Detection (2026-11-05).
final class SpanishScreensATests: XCTestCase {
    func testGuideBodyDropsTheLeadInEitherLanguage() {
        XCTAssertEqual(AppInstructionsView.guideBody("Your language: in Settings, pick it."), "In Settings, pick it.")
        XCTAssertEqual(AppInstructionsView.guideBody("Tu idioma: en Ajustes, elígelo."), "En Ajustes, elígelo.")
        XCTAssertEqual(AppInstructionsView.guideBody("No colon here"), "No colon here")
    }

    /// The spoken guide in Spanish gets a Spanish voice, even when the picked voice is English.
    func testSpanishGuideIsReadBySpanishVoice() throws {
        try XCTSkipIf(YourLanguageVoice.best(for: "es") == nil, "no Spanish voice on this simulator")
        let english = YourLanguageVoice.best(for: "en")?.identifier
        let out = InstructionsSpeaker.prepared(script: "Bienvenido.", lang: "es", voiceId: english)
        XCTAssertNotNil(out.voice)
        XCTAssertTrue(out.voice.map { YourLanguageVoice.speaks($0, "es") } ?? false)
        XCTAssertEqual(out.text, "Bienvenido.")
    }

    func testEnglishGuideKeepsAnEnglishVoice() throws {
        try XCTSkipIf(YourLanguageVoice.best(for: "en") == nil, "no English voice")
        let out = InstructionsSpeaker.prepared(script: "Welcome.", lang: "en", voiceId: nil)
        XCTAssertTrue(out.voice.map { YourLanguageVoice.speaks($0, "en") } ?? false)
    }

    func testCatalogHasSpanishForTheseScreens() {
        for key in ["Object Detection", "Settings", "Detection sensitivity", "Voice, %@", "Home screen",
                    "Getting the %@ model for this phone, %@. What's this? keeps working while it downloads."] {
            XCTAssertTrue(AppLang.hasSpanish(key), key)
        }
        XCTAssertEqual(AppLang.text("Back", in: "es"), "Atrás")
        XCTAssertEqual(AppLang.text("Back", in: "en"), "Back")
    }
}
