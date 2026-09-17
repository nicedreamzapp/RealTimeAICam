@testable import RealTime_Ai_Cam
import CoreGraphics
import Foundation
import Testing

// Boxes are normalized, origin TOP-LEFT, y grows downward (HelpMeAim.swift header).

private func box(midX: CGFloat, midY: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
    CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
}

private func close(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 1e-9) -> Bool {
    abs(a.minX - b.minX) < eps && abs(a.minY - b.minY) < eps
        && abs(a.width - b.width) < eps && abs(a.height - b.height) < eps
}

// MARK: - Subject

struct AimSubjectTests {
    @Test func faceUsesPersonFramingEverythingElseWhole() {
        #expect(AimSubject.face.framing == .person)
        #expect(AimSubject.page.framing == .whole)
        let key = AimVocabulary.Match(spokenName: "key", classNames: ["key"], classIDs: [0])
        #expect(AimSubject.object(key).framing == .whole)
    }

    @Test func spokenNames() {
        #expect(AimSubject.face.spokenName == "a face")
        #expect(AimSubject.page.spokenName == "a picture or page")
        let key = AimVocabulary.Match(spokenName: "key", classNames: ["key"], classIDs: [0])
        #expect(AimSubject.object(key).spokenName == "a key")
        let apple = AimVocabulary.Match(spokenName: "apple", classNames: ["apple"], classIDs: [1])
        #expect(AimSubject.object(apple).spokenName == "an apple")
    }
}

// MARK: - Rotation

struct AimRotationTests {
    @Test func oneQuarterTurnMapsTopLeftToTopRight() {
        let b = CGRect(x: 0, y: 0, width: 0.2, height: 0.1)
        #expect(close(AimSteering.rotateClockwise(b, quarterTurns: 1),
                      CGRect(x: 0.9, y: 0, width: 0.1, height: 0.2)))
    }

    @Test func fourTurnsIsIdentityAndNegativeWraps() {
        let b = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        #expect(close(AimSteering.rotateClockwise(b, quarterTurns: 4), b))
        #expect(close(AimSteering.rotateClockwise(b, quarterTurns: 0), b))
        #expect(close(AimSteering.rotateClockwise(b, quarterTurns: -1),
                      AimSteering.rotateClockwise(b, quarterTurns: 3)))
    }

    @Test func twoTurnsFlipsBothAxes() {
        let b = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        #expect(close(AimSteering.rotateClockwise(b, quarterTurns: 2),
                      CGRect(x: 0.6, y: 0.4, width: 0.3, height: 0.4)))
    }

    @Test func quarterTurnsFromLevelAngle() {
        #expect(AimSteering.quarterTurns(levelAngle: 90) == 0)
        #expect(AimSteering.quarterTurns(levelAngle: 180) == 1)
        #expect(AimSteering.quarterTurns(levelAngle: 270) == 2)
        #expect(AimSteering.quarterTurns(levelAngle: 0) == 3)
        #expect(AimSteering.quarterTurns(levelAngle: 88) == 0)
    }
}

// MARK: - Phrases

struct AimPhrasesTests {
    @Test func steeringPhrasesArePixelStyle() {
        #expect(AimPhrases.phrase(for: .moveLeft, subject: .face) == "move the phone left")
        #expect(AimPhrases.phrase(for: .moveRight, subject: .face) == "move the phone right")
        #expect(AimPhrases.phrase(for: .moveUp, subject: .face) == "move the phone up")
        #expect(AimPhrases.phrase(for: .moveDown, subject: .face) == "move the phone down")
        #expect(AimPhrases.phrase(for: .moveCloser, subject: .page) == "move closer")
        #expect(AimPhrases.phrase(for: .backUp, subject: .page) == "back up")
    }

    @Test func framedIsGotIt() {
        #expect(AimPhrases.phrase(for: .framed, subject: .page) == "got it, hold still")
        #expect(AimPhrases.phrase(for: .framed, subject: .face) == "got it, hold still")
        #expect(AimPhrases.phrase(for: .framed, subject: .face, faceCount: 2) == "got it, two faces, hold still")
        // Face count only matters for faces.
        #expect(AimPhrases.phrase(for: .framed, subject: .page, faceCount: 3) == "got it, hold still")
    }

    @Test func notFoundNamesTheSubject() {
        #expect(AimPhrases.phrase(for: .notFound, subject: .face)
            == "I don't see a face yet, move the phone slowly")
    }

    @Test func countWords() {
        #expect(AimPhrases.countWord(0) == "zero")
        #expect(AimPhrases.countWord(10) == "ten")
        #expect(AimPhrases.countWord(11) == "many")
        #expect(AimPhrases.countWord(-1) == "many")
    }

    @Test func cantLookFor() {
        #expect(AimPhrases.cantLookFor("  unicorn ") == "I can't look for unicorn yet")
        #expect(AimPhrases.cantLookFor("   ") == "I didn't catch that. Tap Speak to try again.")
    }

    @Test func capitalizedAndCountdown() {
        #expect(AimPhrases.capitalized("got it") == "Got it")
        #expect(AimPhrases.capitalized("") == "")
        #expect(AimPhrases.countdown == ["3", "2", "1"])
    }
}

// MARK: - Vocabulary

struct AimVocabularyTests {
    // Index position is the class ID. "key" appears twice on purpose.
    private let names = ["person", "key", "Picture Frame", "poster", "dog",
                         "glasses", "mug", "cup", "television", "box", "key", "battery", "knife"]

    @Test func pluralKeysMatchesKey() throws {
        let m = try #require(AimVocabulary.match("keys", classNames: names))
        #expect(m.spokenName == "key")
        #expect(m.classNames == ["key"])
        #expect(m.classIDs == [1, 10])
    }

    @Test func paintingMatchesPictureFrameAndPoster() throws {
        let m = try #require(AimVocabulary.match("Painting", classNames: names))
        #expect(m.spokenName == "painting")
        #expect(m.classNames == ["picture frame", "poster"])
        #expect(m.classIDs == [2, 3])
    }

    @Test func unknownWordHasNoMatch() {
        #expect(AimVocabulary.match("zebra", classNames: names) == nil)
        #expect(AimVocabulary.match("zebras", classNames: names) == nil)
        #expect(AimVocabulary.match("", classNames: names) == nil)
        #expect(AimVocabulary.match("   ", classNames: names) == nil)
        #expect(AimVocabulary.match("?!", classNames: names) == nil)
    }

    @Test func synonymWithNoRealClassDoesNotInventOne() {
        // "wallet" -> wallet/purse, neither in this vocabulary.
        #expect(AimVocabulary.match("wallet", classNames: names) == nil)
    }

    @Test func fillerWordsAreStripped() throws {
        let m = try #require(AimVocabulary.match("Where’s my KEYS?", classNames: names))
        #expect(m.spokenName == "key")
        let d = try #require(AimVocabulary.match("I want a picture of my dog", classNames: names))
        #expect(d.spokenName == "dog")
        #expect(d.classIDs == [4])
    }

    @Test func multiWordSynonym() throws {
        let m = try #require(AimVocabulary.match("I'm looking for my house keys", classNames: names))
        #expect(m.spokenName == "house key")
        #expect(m.classNames == ["key"])
        let g = try #require(AimVocabulary.match("guide dog", classNames: names))
        #expect(g.classNames == ["dog"])
        let t = try #require(AimVocabulary.match("TV", classNames: names))
        #expect(t.classNames == ["television"])
    }

    @Test func unknownPhraseFallsBackToLastWord() throws {
        let m = try #require(AimVocabulary.match("find my red keys", classNames: names))
        #expect(m.spokenName == "key")
    }

    @Test func mugSynonymKeepsOrderAndSkipsMissing() throws {
        // mug -> mug, cup, coffee cup ("coffee cup" not in the vocabulary).
        let m = try #require(AimVocabulary.match("mugs", classNames: names))
        #expect(m.classNames == ["mug", "cup"])
        #expect(m.classIDs == [6, 7])
    }

    @Test func pluralForms() {
        #expect(AimVocabulary.match("glasses", classNames: names)?.spokenName == "glasses")
        #expect(AimVocabulary.match("boxes", classNames: names)?.spokenName == "box")
        #expect(AimVocabulary.match("batteries", classNames: names)?.spokenName == "battery")
        #expect(AimVocabulary.match("knives", classNames: names)?.spokenName == "knife")
    }

    @Test func formsOf() {
        #expect(AimVocabulary.forms(of: "glass") == ["glass"])
        #expect(AimVocabulary.forms(of: "batteries").contains("battery"))
        #expect(AimVocabulary.forms(of: "knives").contains("knife"))
        #expect(AimVocabulary.forms(of: "keys") == ["keys", "key"])
    }

    @Test func normalize() {
        #expect(AimVocabulary.normalize("  The   T-Shirt!! ") == "t shirt")
        #expect(AimVocabulary.normalize("my") == "my") // a filler alone is kept
        #expect(AimVocabulary.normalize("find the cup") == "cup")
    }

    @Test func indexLowercasesAndCollectsDuplicates() {
        let idx = AimVocabulary.index(["Key", "cup", "key"])
        #expect(idx["key"] == [0, 2])
        #expect(idx["cup"] == [1])
        #expect(idx["Key"] == nil)
    }

    @Test func withArticle() {
        #expect(AimVocabulary.withArticle("key") == "a key")
        #expect(AimVocabulary.withArticle("apple") == "an apple")
        #expect(AimVocabulary.withArticle("Umbrella") == "an Umbrella")
        #expect(AimVocabulary.withArticle("") == "")
    }
}
