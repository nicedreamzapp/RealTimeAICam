import XCTest
@testable import RealTime_Ai_Cam

final class AppLangTests: XCTestCase {
    func testSpanishPhoneIsSpanish() {
        XCTAssertEqual(AppLang.uiCode(appLanguage: "es", yourLanguage: "en"), "es")
        XCTAssertEqual(AppLang.uiCode(appLanguage: "es-MX", yourLanguage: "fr"), "es")
    }

    func testYourLanguageSpanishOnAnEnglishPhoneIsSpanish() {
        XCTAssertEqual(AppLang.uiCode(appLanguage: "en", yourLanguage: "es"), "es")
    }

    func testEverythingElseIsEnglish() {
        XCTAssertEqual(AppLang.uiCode(appLanguage: "en", yourLanguage: "en"), "en")
        XCTAssertEqual(AppLang.uiCode(appLanguage: "fr", yourLanguage: "fr"), "en")
        XCTAssertEqual(AppLang.uiCode(appLanguage: nil, yourLanguage: "de"), "en")
    }

    func testCatalogHasSpanishForTheGuide() {
        XCTAssertTrue(AppLang.hasSpanish("Speech enabled"))
        XCTAssertEqual(AppLang.text("Speech enabled", in: "es"), "Voz activada")
        XCTAssertEqual(AppLang.text("Speech enabled", in: "en"), "Speech enabled")
    }

    /// Every key the code uses has Spanish (the catalog is checked by ios/tools/es-strings.py missing too).
    func testFormatKeysKeepTheirArguments() {
        let es = AppLang.text("Downloading %@, one time only.", in: "es")
        XCTAssertEqual(String(format: es, "español"), "Descargando español, solo esta vez.")
    }
}
