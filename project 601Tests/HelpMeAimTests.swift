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

// MARK: - Steering, whole objects

struct AimSteeringWholeTests {
    private func say(_ b: CGRect?, loose: Bool = false) -> AimInstruction {
        AimSteering.instruction(for: b, framing: .whole, loose: loose)
    }

    @Test func noBoxIsNotFound() {
        #expect(say(nil) == .notFound)
        #expect(say(CGRect(x: 0.4, y: 0.4, width: 0, height: 0.2)) == .notFound)
        #expect(say(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0)) == .notFound)
    }

    @Test func centeredAndBigEnoughIsFramed() {
        #expect(say(box(midX: 0.5, midY: 0.5, w: 0.5, h: 0.5)) == .framed)
    }

    @Test func subjectOnLeftMovesPhoneLeft() {
        #expect(say(box(midX: 0.2, midY: 0.5, w: 0.3, h: 0.3)) == .moveLeft)
    }

    @Test func subjectOnRightMovesPhoneRight() {
        #expect(say(box(midX: 0.8, midY: 0.5, w: 0.3, h: 0.3)) == .moveRight)
    }

    @Test func subjectNearTopMovesPhoneUp() {
        // Small y = top of the picture.
        #expect(say(box(midX: 0.5, midY: 0.2, w: 0.3, h: 0.3)) == .moveUp)
    }

    @Test func subjectNearBottomMovesPhoneDown() {
        #expect(say(box(midX: 0.5, midY: 0.8, w: 0.3, h: 0.3)) == .moveDown)
    }

    @Test func largerOffsetWinsOnADiagonal() {
        #expect(say(box(midX: 0.15, midY: 0.3, w: 0.26, h: 0.26)) == .moveLeft)
        #expect(say(box(midX: 0.4, midY: 0.85, w: 0.26, h: 0.26)) == .moveDown)
    }

    @Test func cutOffEdgeMovesTowardThatEdge() {
        #expect(say(CGRect(x: 0, y: 0.3, width: 0.4, height: 0.4)) == .moveLeft)
        #expect(say(CGRect(x: 0.6, y: 0.3, width: 0.4, height: 0.4)) == .moveRight)
        #expect(say(CGRect(x: 0.3, y: 0, width: 0.4, height: 0.4)) == .moveUp)
        #expect(say(CGRect(x: 0.3, y: 0.6, width: 0.4, height: 0.4)) == .moveDown)
    }

    @Test func cutOffOnOppositeSidesBacksUp() {
        #expect(say(CGRect(x: 0, y: 0.3, width: 1, height: 0.4)) == .backUp)
        #expect(say(CGRect(x: 0.3, y: 0, width: 0.4, height: 1)) == .backUp)
    }

    @Test func nearlyFullFrameBacksUp() {
        #expect(say(box(midX: 0.5, midY: 0.5, w: 0.96, h: 0.5)) == .backUp)
        #expect(say(box(midX: 0.5, midY: 0.5, w: 0.5, h: 0.96)) == .backUp)
    }

    @Test func smallCenteredSubjectMovesCloser() {
        #expect(say(box(midX: 0.5, midY: 0.5, w: 0.1, h: 0.1)) == .moveCloser)
    }

    @Test func looseToleranceKeepsAWobbleFramed() {
        let wobble = box(midX: 0.5 + 0.18, midY: 0.5, w: 0.3, h: 0.3)
        #expect(say(wobble) == .moveRight)
        #expect(say(wobble, loose: true) == .framed)
    }
}

// MARK: - Steering, faces

struct AimSteeringPersonTests {
    private func say(_ b: CGRect?, loose: Bool = false) -> AimInstruction {
        AimSteering.instruction(for: b, framing: .person, loose: loose)
    }

    @Test func smallFaceInUpperThirdIsFramed() {
        #expect(say(box(midX: 0.5, midY: 1.0 / 3.0, w: 0.15, h: 0.2)) == .framed)
    }

    @Test func smallFaceDeadCenterIsTooLowSoMovePhoneDown() {
        // "Centered" is the wrong target for a person; the face belongs higher.
        #expect(say(box(midX: 0.5, midY: 0.5, w: 0.15, h: 0.2)) == .moveDown)
    }

    @Test func smallFaceAtTheTopMovesPhoneUp() {
        #expect(say(box(midX: 0.5, midY: 0.15, w: 0.15, h: 0.2)) == .moveUp)
    }

    @Test func closeUpFaceBelongsInTheMiddle() {
        #expect(say(box(midX: 0.5, midY: 0.5, w: 0.4, h: 0.5)) == .framed)
        // The same close-up up in the top third is now too high.
        #expect(say(box(midX: 0.5, midY: 1.0 / 3.0, w: 0.4, h: 0.5)) == .moveUp)
    }

    @Test func inBetweenFaceSizeAcceptsEitherTarget() {
        #expect(say(box(midX: 0.5, midY: 1.0 / 3.0, w: 0.3, h: 0.35)) == .framed)
        #expect(say(box(midX: 0.5, midY: 0.5, w: 0.3, h: 0.35)) == .framed)
    }

    @Test func faceOffToTheSidesSteersHorizontally() {
        #expect(say(box(midX: 0.2, midY: 1.0 / 3.0, w: 0.15, h: 0.2)) == .moveLeft)
        #expect(say(box(midX: 0.8, midY: 1.0 / 3.0, w: 0.15, h: 0.2)) == .moveRight)
    }

    @Test func faceTouchingAnEdgeIsFixedFirst() {
        #expect(say(CGRect(x: 0.4, y: 0.01, width: 0.15, height: 0.2)) == .moveUp)
        #expect(say(CGRect(x: 0.4, y: 0.8, width: 0.15, height: 0.2)) == .moveDown)
        #expect(say(CGRect(x: 0.0, y: 0.25, width: 0.15, height: 0.2)) == .moveLeft)
        #expect(say(CGRect(x: 0.85, y: 0.25, width: 0.15, height: 0.2)) == .moveRight)
    }

    @Test func tinyFaceMovesCloser() {
        #expect(say(box(midX: 0.5, midY: 1.0 / 3.0, w: 0.08, h: 0.1)) == .moveCloser)
    }

    @Test func hugeFaceBacksUp() {
        #expect(say(box(midX: 0.5, midY: 0.5, w: 0.5, h: 0.7)) == .backUp)
        // Loose allows a bit more while the countdown runs.
        #expect(say(box(midX: 0.5, midY: 0.5, w: 0.5, h: 0.68), loose: true) != .backUp)
    }

    @Test func looseToleranceKeepsAWobbleFramed() {
        let wobble = box(midX: 0.5 + 0.15, midY: 1.0 / 3.0, w: 0.15, h: 0.2)
        #expect(say(wobble) == .moveRight)
        #expect(say(wobble, loose: true) == .framed)
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
        #expect(AimPhrases.cantLookFor("   ") == "I didn't catch that, try again")
    }

    @Test func capitalizedAndCountdown() {
        #expect(AimPhrases.capitalized("got it") == "Got it")
        #expect(AimPhrases.capitalized("") == "")
        #expect(AimPhrases.countdown == ["3", "2", "1"])
    }
}

// MARK: - Coach

struct AimCoachTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private let framedPage = box(midX: 0.5, midY: 0.5, w: 0.5, h: 0.5)
    private let leftPage = CGRect(x: 0.05, y: 0.25, width: 0.3, height: 0.5)
    private let rightPage = CGRect(x: 0.65, y: 0.25, width: 0.3, height: 0.5)

    private func newCoach() -> AimCoach {
        var c = AimCoach(subject: .page)
        c.reset(now: t0)
        return c
    }

    /// Frames until the countdown starts; returns the coach mid-countdown.
    private func countingDownCoach() -> AimCoach {
        var c = newCoach()
        _ = c.observe(box: framedPage, now: at(0), voiceBusy: false)
        _ = c.observe(box: framedPage, now: at(0.1), voiceBusy: false)
        _ = c.observe(box: framedPage, now: at(0.7), voiceBusy: false)
        return c
    }

    @Test func steeringNeedsTwoFramesInARow() {
        var c = newCoach()
        #expect(c.observe(box: leftPage, now: at(0), voiceBusy: false) == [])
        #expect(c.observe(box: leftPage, now: at(0.1), voiceBusy: false)
            == [.say("move the phone left", .tick)])
    }

    @Test func samePhraseIsNotRepeatedInsideRepeatInterval() {
        var c = newCoach()
        _ = c.observe(box: leftPage, now: at(0), voiceBusy: false)
        _ = c.observe(box: leftPage, now: at(0.1), voiceBusy: false)
        for s in stride(from: 0.2, through: 2.0, by: 0.1) {
            #expect(c.observe(box: leftPage, now: at(s), voiceBusy: false) == [])
        }
        #expect(c.observe(box: leftPage, now: at(2.2), voiceBusy: false)
            == [.say("move the phone left", .tick)])
    }

    @Test func differentPhraseWaitsForMinGap() {
        var c = newCoach()
        _ = c.observe(box: leftPage, now: at(0), voiceBusy: false)
        _ = c.observe(box: leftPage, now: at(0.1), voiceBusy: false) // said "left"
        // The smoothed box slides right over a few frames (passing through
        // "framed" on the way); by 0.5 s "right" is debounced, but it is still
        // inside minGap of "left", so nothing is said until 0.9 s.
        for s in [0.3, 0.4, 0.5, 0.6, 0.7] {
            #expect(c.observe(box: rightPage, now: at(s), voiceBusy: false) == [])
        }
        #expect(c.observe(box: rightPage, now: at(0.95), voiceBusy: false)
            == [.say("move the phone right", .tick)])
    }

    @Test func nothingIsSaidWhileVoiceIsBusy() {
        var c = newCoach()
        _ = c.observe(box: leftPage, now: at(0), voiceBusy: true)
        #expect(c.observe(box: leftPage, now: at(0.1), voiceBusy: true) == [])
        #expect(c.observe(box: leftPage, now: at(0.2), voiceBusy: false)
            == [.say("move the phone left", .tick)])
    }

    @Test func notFoundWaitsThenRepeatsSlowly() {
        var c = newCoach()
        let text = AimPhrases.phrase(for: .notFound, subject: .page)
        #expect(c.observe(box: nil, now: at(0), voiceBusy: false) == [])
        #expect(c.observe(box: nil, now: at(2.9), voiceBusy: false) == [])
        #expect(c.observe(box: nil, now: at(3.1), voiceBusy: false) == [.say(text, .none)])
        #expect(c.observe(box: nil, now: at(5.0), voiceBusy: false) == [])
        #expect(c.observe(box: nil, now: at(9.0), voiceBusy: false) == [])
        #expect(c.observe(box: nil, now: at(9.2), voiceBusy: false) == [.say(text, .none)])
    }

    @Test func briefDropoutStillCountsAsSeen() {
        var c = newCoach()
        _ = c.observe(box: leftPage, now: at(0), voiceBusy: false)
        _ = c.observe(box: leftPage, now: at(0.1), voiceBusy: false)
        // Gone for 0.3 s: the held box is still there.
        _ = c.observe(box: nil, now: at(0.4), voiceBusy: false)
        #expect(c.smoothedBox != nil)
        // Gone longer than holdLastBox: dropped.
        _ = c.observe(box: nil, now: at(1.0), voiceBusy: false)
        #expect(c.smoothedBox == nil)
    }

    @Test func framedSaysGotItOnceThenStartsCountdown() {
        var c = newCoach()
        #expect(c.observe(box: framedPage, now: at(0), voiceBusy: false) == [])
        #expect(c.observe(box: framedPage, now: at(0.1), voiceBusy: false)
            == [.say("got it, hold still", .success)])
        // Steady clock starts after the sentence: not yet 0.5 s.
        #expect(c.observe(box: framedPage, now: at(0.3), voiceBusy: false) == [])
        #expect(c.isCountingDown == false)
        #expect(c.observe(box: framedPage, now: at(0.7), voiceBusy: false) == [.startCountdown])
        #expect(c.isCountingDown)
    }

    @Test func countdownStartsOnlyOnceWhileHeldSteady() {
        var c = countingDownCoach()
        #expect(c.isCountingDown)
        var all: [AimCoach.Action] = []
        for s in stride(from: 0.8, through: 4.0, by: 0.1) {
            all += c.observe(box: framedPage, now: at(s), voiceBusy: false)
        }
        #expect(all.isEmpty)
    }

    @Test func countdownWaitsForVoiceToFinish() {
        var c = newCoach()
        _ = c.observe(box: framedPage, now: at(0), voiceBusy: false)
        _ = c.observe(box: framedPage, now: at(0.1), voiceBusy: false)
        #expect(c.observe(box: framedPage, now: at(0.7), voiceBusy: true) == [])
        #expect(c.observe(box: framedPage, now: at(0.8), voiceBusy: false) == [.startCountdown])
    }

    @Test func driftBeforeCountdownRestartsSteadyClock() {
        var c = newCoach()
        _ = c.observe(box: framedPage, now: at(0), voiceBusy: false)
        _ = c.observe(box: framedPage, now: at(0.1), voiceBusy: false) // got it
        // Still framed, but moved more than steadyDrift: clock restarts.
        let nudged = framedPage.offsetBy(dx: 0.12, dy: 0)
        #expect(c.observe(box: nudged, now: at(0.7), voiceBusy: false) == [])
        #expect(c.isCountingDown == false)
    }

    @Test func oneBadFrameDoesNotCancelCountdown() {
        var c = countingDownCoach()
        #expect(c.observe(box: nil, now: at(1.5), voiceBusy: false) == [])
        #expect(c.isCountingDown)
        #expect(c.observe(box: framedPage, now: at(1.6), voiceBusy: false) == [])
        #expect(c.isCountingDown)
    }

    @Test func driftDuringCountdownCancelsWithLostIt() {
        var c = countingDownCoach()
        let farLeft = CGRect(x: 0, y: 0.4, width: 0.2, height: 0.2)
        #expect(c.observe(box: farLeft, now: at(0.8), voiceBusy: false) == [])
        #expect(c.observe(box: farLeft, now: at(0.9), voiceBusy: false)
            == [.cancelCountdown, .say(AimPhrases.lostIt, .warning)])
        #expect(c.isCountingDown == false)
    }

    @Test func losingTheSubjectDuringCountdownCancels() {
        var c = countingDownCoach()
        #expect(c.observe(box: nil, now: at(1.5), voiceBusy: false) == [])
        #expect(c.observe(box: nil, now: at(1.6), voiceBusy: false)
            == [.cancelCountdown, .say(AimPhrases.lostIt, .warning)])
    }

    @Test func countdownEndedAllowsANewRound() {
        var c = countingDownCoach()
        c.countdownEnded()
        #expect(c.isCountingDown == false)
        _ = c.observe(box: framedPage, now: at(5.0), voiceBusy: false)
        _ = c.observe(box: framedPage, now: at(5.1), voiceBusy: false)
        #expect(c.observe(box: framedPage, now: at(5.7), voiceBusy: false) == [.startCountdown])
    }

    @Test func resetClearsCountdownAndBox() {
        var c = countingDownCoach()
        c.reset(now: at(10))
        #expect(c.isCountingDown == false)
        #expect(c.smoothedBox == nil)
        // notFound clock restarts from the reset.
        #expect(c.observe(box: nil, now: at(12), voiceBusy: false) == [])
    }

    @Test func twoFacesAnnouncedByCount() {
        var c = AimCoach(subject: .face)
        c.reset(now: t0)
        let group = box(midX: 0.5, midY: 1.0 / 3.0, w: 0.3, h: 0.2)
        _ = c.observe(box: group, faceCount: 2, now: at(0), voiceBusy: false)
        #expect(c.observe(box: group, faceCount: 2, now: at(0.1), voiceBusy: false)
            == [.say("got it, two faces, hold still", .success)])
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
