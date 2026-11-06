import XCTest
@testable import RealTime_Ai_Cam

/// First-time-user test, 2026-11-04: each screen cue is said once, by one voice.
final class UICueTests: XCTestCase {
    func testVoiceOverOnMeansVoiceOverOnly() {
        XCTAssertEqual(UICue.route(voiceOverRunning: true), .voiceOver)
    }

    func testVoiceOverOffMeansTheAppVoice() {
        XCTAssertEqual(UICue.route(voiceOverRunning: false), .appVoice)
    }

    func testReadHintWhenNothingIsThereYet() {
        XCTAssertTrue(UICue.shouldSayReadHint(hasText: false, speaking: false, openedByLanguagePill: false))
    }

    func testNoReadHintOverTextAlreadyFound() {
        XCTAssertFalse(UICue.shouldSayReadHint(hasText: true, speaking: false, openedByLanguagePill: false))
    }

    func testNoReadHintWhileReading() {
        XCTAssertFalse(UICue.shouldSayReadHint(hasText: false, speaking: true, openedByLanguagePill: false))
    }

    func testNoReadHintAfterTheLanguagePillSwitchedReaders() {
        XCTAssertFalse(UICue.shouldSayReadHint(hasText: false, speaking: false, openedByLanguagePill: true))
    }

    func testCueWordsMatchAndroid() {
        XCTAssertEqual(UICue.home, "Home")
        XCTAssertEqual(UICue.readHint, "Point the camera at some text")
    }

    /// A Spanish app says its cues from the catalog: a missing entry came out in English
    /// with the Spanish voice on a real iPhone (2026-11-05).
    func testCuesHaveSpanish() {
        XCTAssertTrue(AppLang.hasSpanish(UICue.home))
        XCTAssertTrue(AppLang.hasSpanish(UICue.readHint))
        XCTAssertEqual(AppLang.text(UICue.readHint, in: "es"), "Apunta la cámara a un texto")
        // The L() list the strings tool reads must stay the same words as the cues.
        XCTAssertEqual(UICue.keysSaidByKey, [UICue.home, UICue.readHint])
    }

    /// The path that said it in English: a Spanish app's cue line, words and language.
    func testSpanishAppSaysTheCueInSpanish() async {
        UserDefaults.standard.set("es", forKey: AppLang.forcedKey)
        defer { UserDefaults.standard.removeObject(forKey: AppLang.forcedKey) }
        let read = await UICue.line(UICue.readHint)
        XCTAssertEqual(read.text, "Apunta la cámara a un texto")
        XCTAssertEqual(read.lang, "es")
        let home = await UICue.line(UICue.home)
        XCTAssertEqual(home.text, "Inicio")
        XCTAssertEqual(home.lang, "es")
        // A cue the catalog lacks: English words get the English voice, not the Spanish one.
        let missing = await UICue.line("A cue with no Spanish yet")
        XCTAssertEqual(missing.text, "A cue with no Spanish yet")
        XCTAssertEqual(missing.lang, "en")
    }
}
