@testable import RealTime_Ai_Cam
import CoreGraphics
import Foundation
import Testing

/// Vocabulary regression tests: the thing before a preposition wins over the
/// last word, and the real bundled list covers the common asks.
struct HelpMeAimFixTests {
    @Test func thingBeforeAPrepositionWins() throws {
        // "red" and "car" are real YOLOE classes; the thing asked for is the keys.
        let vocab = ["red", "car", "key", "house"]
        let a = try #require(AimVocabulary.match("keys to the car", classNames: vocab))
        #expect(a.spokenName == "key")
        let b = try #require(AimVocabulary.match("my red keys", classNames: vocab))
        #expect(b.spokenName == "key")
        let c = try #require(AimVocabulary.match("my house keys", classNames: vocab))
        #expect(c.spokenName == "house key")
    }

    @Test func realVocabularyHasTheCommonAsks() throws {
        // The bundled 4,585-name list, as shipped.
        let names = AimObjectFinder.loadClassNames()
        try #require(names.count == 4585)
        #expect(AimVocabulary.match("keys", classNames: names)?.classNames == ["key"])
        #expect(AimVocabulary.match("painting", classNames: names)?.classNames.contains("picture frame") == true)
        #expect(AimVocabulary.match("cell phone", classNames: names)?.classNames.contains("phone") == true)
        #expect(AimVocabulary.match("remote control", classNames: names)?.classNames.contains("remote") == true)
        #expect(AimVocabulary.match("wallet", classNames: names) == nil)
    }
}
