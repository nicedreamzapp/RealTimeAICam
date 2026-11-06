import XCTest
@testable import RealTime_Ai_Cam

/// Read and What's this? in the app's language (2026-11-05): the countdown, the cut-off
/// sentence and the download line pick their words by language, never by the phone.
final class WhatsThisSpanishTests: XCTestCase {
    func testCountdownIsSpanishInASpanishVoice() {
        let c = LiveOCRViewModel.countdownWords(lang: "es", hasVoice: true)
        XCTAssertEqual(c.lang, "es")
        XCTAssertEqual(c.words, ["tres", "dos", "uno"])
    }

    func testCountdownStaysEnglishInEnglish() {
        let c = LiveOCRViewModel.countdownWords(lang: "en", hasVoice: true)
        XCTAssertEqual(c.lang, "en")
        XCTAssertEqual(c.words, ["three", "two", "one"])
    }

    /// No Spanish voice on the phone: English words for the English voice, never "tres" in English.
    func testCountdownWithNoVoiceForTheLanguageIsEnglish() {
        let c = LiveOCRViewModel.countdownWords(lang: "es", hasVoice: false)
        XCTAssertEqual(c.lang, "en")
        XCTAssertEqual(c.words, ["three", "two", "one"])
    }

    /// The cut-off sentence follows the answer's language, not the phone's.
    func testCutOffSentenceMatchesTheAnswer() {
        let key = LiveOCRView.cutOffPrefix("top")
        XCTAssertEqual(LiveOCRView.withPrefix(key, "Una carta.", lang: "es"), "Cortado arriba. Una carta.")
        XCTAssertEqual(LiveOCRView.withPrefix(key, "A letter.", lang: "en"), "Cut off at the top. A letter.")
        XCTAssertEqual(LiveOCRView.withPrefix(LiveOCRView.cutOffPrefix(nil), "A letter.", lang: "es"), "A letter.")
    }

    func testCatalogHasTheSpokenLines() {
        for key in ["That picture couldn't be opened.", "Sorry, I couldn't work that out. Try asking again.",
                    "Saved to your photos with that description.", "Tap to read", "Auto read", "Mute"] {
            XCTAssertTrue(AppLang.hasSpanish(key), key)
        }
        XCTAssertEqual(String(format: AppLang.text("Downloading %@, one time only. After that it works offline.", in: "es"), "francés"),
                       "Descargando francés, solo esta vez. Después funciona sin conexión.")
    }
}
