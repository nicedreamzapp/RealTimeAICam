@testable import RealTime_Ai_Cam
import CoreGraphics
import Foundation
import Testing

// Round 2 of Help Me Aim (Matt's field test 2026-09-16: shot ~1 in 30 tries,
// chattered left/right/down). Boxes: normalized, top-left origin, y down.

private func rect(midX: CGFloat, midY: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
    CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
}

// MARK: - Loosened steering

struct AimRound2SteeringTests {
    private func whole(_ b: CGRect?, loose: Bool = false) -> AimInstruction {
        AimSteering.instruction(for: b, framing: .whole, loose: loose)
    }

    private func person(_ b: CGRect?, loose: Bool = false) -> AimInstruction {
        AimSteering.instruction(for: b, framing: .person, loose: loose)
    }

    @Test func middleHalfIsGoodEnough() {
        #expect(whole(rect(midX: 0.5, midY: 0.5, w: 0.3, h: 0.3)) == .framed)
        #expect(whole(rect(midX: 0.72, midY: 0.3, w: 0.3, h: 0.3)) == .framed)
        #expect(whole(rect(midX: 0.8, midY: 0.5, w: 0.3, h: 0.3)) == .moveRight)
        #expect(whole(rect(midX: 0.5, midY: 0.2, w: 0.3, h: 0.3)) == .moveUp)
    }

    @Test func looseZoneIsMuchWider() {
        let b = rect(midX: 0.8, midY: 0.5, w: 0.3, h: 0.3)
        #expect(whole(b) == .moveRight)
        #expect(whole(b, loose: true) == .framed)
        #expect(whole(rect(midX: 0.86, midY: 0.5, w: 0.2, h: 0.2), loose: true) == .moveRight)
    }

    @Test func acrossTheRoomIsNotMoveCloser() {
        #expect(whole(rect(midX: 0.5, midY: 0.5, w: 0.15, h: 0.12)) == .framed)
        #expect(whole(rect(midX: 0.5, midY: 0.5, w: 0.09, h: 0.08)) == .moveCloser)
        #expect(whole(rect(midX: 0.5, midY: 0.5, w: 0.09, h: 0.08), loose: true) == .framed)
    }

    @Test func cutOffOnlyWhenReallyTouchingTheEdge() {
        #expect(whole(CGRect(x: 0.01, y: 0.2, width: 0.6, height: 0.5)) == .framed)
        #expect(whole(CGRect(x: 0.0, y: 0.2, width: 0.6, height: 0.5)) == .moveLeft)
        #expect(whole(CGRect(x: 0.3, y: 0.2, width: 0.7, height: 0.5)) == .moveRight)
        #expect(whole(CGRect(x: 0.0, y: 0.2, width: 1.0, height: 0.5)) == .backUp)
    }

    @Test func faceZoneAroundUpperThird() {
        #expect(person(rect(midX: 0.5, midY: 1.0 / 3.0, w: 0.15, h: 0.2)) == .framed)
        #expect(person(rect(midX: 0.5, midY: 0.5, w: 0.15, h: 0.2)) == .framed)
        #expect(person(rect(midX: 0.5, midY: 0.6, w: 0.15, h: 0.2)) == .moveDown)
        #expect(person(rect(midX: 0.2, midY: 1.0 / 3.0, w: 0.15, h: 0.2)) == .moveLeft)
        #expect(person(rect(midX: 0.75, midY: 1.0 / 3.0, w: 0.15, h: 0.2)) == .moveRight)
        #expect(person(rect(midX: 0.75, midY: 1.0 / 3.0, w: 0.15, h: 0.2), loose: true) == .framed)
    }

    @Test func faceSizeLimits() {
        #expect(person(rect(midX: 0.5, midY: 1.0 / 3.0, w: 0.06, h: 0.07)) == .moveCloser)
        #expect(person(rect(midX: 0.5, midY: 1.0 / 3.0, w: 0.09, h: 0.1)) == .framed)
        #expect(person(rect(midX: 0.5, midY: 0.5, w: 0.6, h: 0.8)) == .backUp)
        #expect(person(rect(midX: 0.5, midY: 0.5, w: 0.6, h: 0.8), loose: true) != .backUp)
        #expect(person(CGRect(x: 0.4, y: 0.0, width: 0.15, height: 0.2)) == .moveUp)
    }

    @Test func framingTargets() {
        let w = AimSteering.target(for: rect(midX: 0.1, midY: 0.1, w: 0.2, h: 0.2), framing: .whole)
        #expect(abs(w.x - 0.5) < 1e-9 && abs(w.y - 0.5) < 1e-9)
        let small = AimSteering.target(for: rect(midX: 0.5, midY: 0.5, w: 0.2, h: 0.2), framing: .person)
        #expect(abs(small.y - 1.0 / 3.0) < 1e-9)
        let close = AimSteering.target(for: rect(midX: 0.5, midY: 0.5, w: 0.4, h: 0.5), framing: .person)
        #expect(abs(close.y - 0.5) < 1e-9)
        let mid = AimSteering.target(for: rect(midX: 0.5, midY: 0.5, w: 0.3, h: 0.35), framing: .person).y
        #expect(mid > 0.34, "mid was \(mid)")
        #expect(mid < 0.49, "mid was \(mid)")
    }

    @Test func medianIgnoresOneWildBox() throws {
        let boxes = [
            rect(midX: 0.5, midY: 0.5, w: 0.3, h: 0.3),
            rect(midX: 0.52, midY: 0.5, w: 0.3, h: 0.3),
            rect(midX: 0.1, midY: 0.9, w: 0.1, h: 0.1),
            rect(midX: 0.48, midY: 0.5, w: 0.3, h: 0.3),
            rect(midX: 0.5, midY: 0.51, w: 0.3, h: 0.3),
        ]
        let m = try #require(AimCoach.median(boxes))
        #expect(abs(m.midX - 0.5) < 0.02)
        #expect(abs(m.midY - 0.5) < 0.02)
        #expect(AimCoach.median([]) == nil)
    }
}

// MARK: - Coach timing, hysteresis

struct AimRound2CoachTests {
    private let t0 = Date(timeIntervalSince1970: 3_000_000)
    private let framed = rect(midX: 0.5, midY: 0.5, w: 0.3, h: 0.3)
    private let left = rect(midX: 0.1, midY: 0.5, w: 0.15, h: 0.3)
    private let right = rect(midX: 0.9, midY: 0.5, w: 0.15, h: 0.3)
    private let gone = rect(midX: 0.93, midY: 0.5, w: 0.12, h: 0.3) // outside even the loose zone

    private func coach() -> AimCoach {
        var c = AimCoach(subject: .page)
        c.reset(now: t0)
        return c
    }

    /// Feeds frames every 0.1 s from `from` to `to` (inclusive) and returns
    /// every action with its time.
    private func feed(_ c: inout AimCoach, _ box: (Int) -> CGRect?, from: TimeInterval, to: TimeInterval,
                      busy: Bool = false) -> [(t: TimeInterval, a: AimCoach.Action)] {
        var out: [(TimeInterval, AimCoach.Action)] = []
        var i = 0
        var t = from
        while t <= to + 1e-9 {
            for a in c.observe(box: box(i), now: t0.addingTimeInterval(t), voiceBusy: busy) { out.append((t, a)) }
            i += 1
            t += 0.1
        }
        return out
    }

    private func says(_ actions: [(t: TimeInterval, a: AimCoach.Action)]) -> [String] {
        actions.compactMap { if case let .say(s, _) = $0.a { return s } else { return nil } }
    }

    @Test func steeringWaitsHalfASecond() {
        var c = coach()
        let out = feed(&c, { _ in left }, from: 0, to: 1.0)
        #expect(out.count == 1)
        #expect(abs((out.first?.t ?? 0) - 0.5) < 1e-6)
        #expect(says(out) == ["move the phone left"])
    }

    @Test func flipFloppingLeftRightStaysSilent() {
        var c = coach()
        let out = feed(&c, { $0 % 2 == 0 ? left : right }, from: 0, to: 3.0)
        #expect(says(out).isEmpty)
    }

    @Test func jitteryFramedSubjectStillShoots() {
        var c = coach()
        // ±0.06 jitter every frame: more than the old 0.05 steady rule allowed.
        let out = feed(&c, { framed.offsetBy(dx: $0 % 2 == 0 ? 0.06 : -0.06, dy: $0 % 3 == 0 ? 0.04 : -0.03) },
                       from: 0, to: 2.0)
        #expect(says(out) == ["got it, hold still"])
        let starts = out.filter { $0.a == .startCountdown }
        #expect(starts.count == 1)
        let gotItAt = out.first { $0.a == .say("got it, hold still", .success) }?.t ?? 99
        #expect(abs(gotItAt - 0.3) < 1e-6)
        #expect(abs((starts.first?.t ?? 99) - (gotItAt + 0.4)) < 1e-6)
    }

    @Test func countdownWaitsWhileVoiceIsBusy() {
        var c = coach()
        _ = feed(&c, { _ in framed }, from: 0, to: 0.3) // got it at 0.3
        #expect(feed(&c, { _ in framed }, from: 0.4, to: 1.5, busy: true).isEmpty)
        #expect(feed(&c, { _ in framed }, from: 1.6, to: 1.6).map(\.a) == [.startCountdown])
    }

    @Test func briefExcursionAfterGotItIsForgiven() {
        var c = coach()
        _ = feed(&c, { _ in framed }, from: 0, to: 0.3) // got it
        // Busy voice keeps the countdown from starting while we test the lock.
        let away = feed(&c, { _ in gone }, from: 0.4, to: 0.9, busy: true)
        #expect(away.isEmpty)
        #expect(c.isLocked)
        let back = feed(&c, { _ in framed }, from: 1.0, to: 1.5)
        #expect(back.map(\.a).contains(.startCountdown))
        #expect(says(back).isEmpty)
    }

    @Test func leavingForLongUndoesGotIt() {
        var c = coach()
        _ = feed(&c, { _ in framed }, from: 0, to: 0.3)
        let away = feed(&c, { _ in gone }, from: 0.4, to: 2.5, busy: false)
        #expect(!c.isLocked)
        #expect(says(away) == ["move the phone right"])
        #expect(!away.map(\.a).contains(.startCountdown))
    }

    @Test func countdownSurvivesAWobbleButNotALongMiss() {
        var c = coach()
        let start = feed(&c, { _ in framed }, from: 0, to: 0.7)
        #expect(start.map(\.a).contains(.startCountdown))
        #expect(c.isCountingDown)
        #expect(feed(&c, { _ in gone }, from: 0.8, to: 1.3).isEmpty) // 0.5 s out
        #expect(feed(&c, { _ in framed }, from: 1.4, to: 1.6).isEmpty)
        #expect(c.isCountingDown)
        let miss = feed(&c, { _ in nil }, from: 1.7, to: 3.0)
        #expect(miss.first.map { [$0.a] } == [.cancelCountdown])
        #expect(says(miss).first == AimPhrases.lostIt)
        #expect(!c.isCountingDown)
    }

    @Test func noGotItRightAfterACountdownEnds() {
        var c = coach()
        _ = feed(&c, { _ in framed }, from: 0, to: 0.7)
        c.countdownEnded()
        let next = feed(&c, { _ in framed }, from: 5.0, to: 5.2)
        #expect(next.isEmpty)
        #expect(says(feed(&c, { _ in framed }, from: 5.3, to: 5.3)) == ["got it, hold still"])
    }

    @Test func notFoundAfterThreeSecondsThenEverySix() {
        var c = coach()
        let out = feed(&c, { _ in nil }, from: 0, to: 10.0)
        let times = out.map(\.t)
        #expect(times.count == 2)
        #expect(abs((times.first ?? 0) - 3.0) < 1e-6)
        #expect(abs((times.last ?? 0) - 9.0) < 1e-6)
    }

    @Test func samePhraseNotRepeatedWithin2_5s() {
        var c = coach()
        let out = feed(&c, { _ in left }, from: 0, to: 3.2)
        #expect(out.map(\.t).count == 2)
        #expect(abs((out.last?.t ?? 0) - 3.0) < 1e-6)
    }

    @Test func briefDropoutKeepsTheBox() {
        var c = coach()
        _ = feed(&c, { _ in framed }, from: 0, to: 0.2)
        _ = c.observe(box: nil, now: t0.addingTimeInterval(0.7), voiceBusy: false)
        #expect(c.smoothedBox != nil)
        _ = c.observe(box: nil, now: t0.addingTimeInterval(1.0), voiceBusy: false)
        #expect(c.smoothedBox == nil)
    }
}

// MARK: - Burst pick

struct AimBurstPickTests {
    @Test func scoreFormula() throws {
        let f = AimBurst.Frame(box: rect(midX: 0.6, midY: 0.5, w: 0.3, h: 0.3), sharpness: 150)
        let s = try #require(AimBurst.score(f, framing: .whole))
        #expect(abs(s - (1 - 2 * 0.1 + 0.3 * 0.5)) < 1e-9)
        #expect(AimBurst.score(AimBurst.Frame(box: nil, sharpness: 500), framing: .whole) == nil)
        // Sharpness credit is capped.
        let capped = try #require(AimBurst.score(
            AimBurst.Frame(box: rect(midX: 0.5, midY: 0.5, w: 0.3, h: 0.3), sharpness: 9999), framing: .whole))
        #expect(abs(capped - 1.3) < 1e-9)
    }

    @Test func picksTheBestFramed() {
        let frames = [
            AimBurst.Frame(box: rect(midX: 0.7, midY: 0.5, w: 0.3, h: 0.3), sharpness: 200),
            AimBurst.Frame(box: rect(midX: 0.52, midY: 0.5, w: 0.3, h: 0.3), sharpness: 200),
            AimBurst.Frame(box: nil, sharpness: 300),
            AimBurst.Frame(box: CGRect(x: 0, y: 0.35, width: 0.5, height: 0.3), sharpness: 300),
        ]
        #expect(AimBurst.pick(frames, framing: .whole) == 1)
    }

    @Test func cutOffLosesToOffCenter() {
        let frames = [
            AimBurst.Frame(box: CGRect(x: 0.25, y: 0.0, width: 0.5, height: 0.6), sharpness: 300), // cut at top
            AimBurst.Frame(box: rect(midX: 0.75, midY: 0.5, w: 0.3, h: 0.3), sharpness: 20),
        ]
        #expect(AimBurst.pick(frames, framing: .whole) == 1)
    }

    @Test func sharpnessBreaksATie() {
        let b = rect(midX: 0.5, midY: 0.5, w: 0.3, h: 0.3)
        let frames = [AimBurst.Frame(box: b, sharpness: 40), AimBurst.Frame(box: b, sharpness: 220)]
        #expect(AimBurst.pick(frames, framing: .whole) == 1)
    }

    @Test func facesScoreAgainstTheUpperThird() {
        let frames = [
            AimBurst.Frame(box: rect(midX: 0.5, midY: 0.5, w: 0.15, h: 0.2), sharpness: 100),
            AimBurst.Frame(box: rect(midX: 0.5, midY: 0.34, w: 0.15, h: 0.2), sharpness: 100),
        ]
        #expect(AimBurst.pick(frames, framing: .person) == 1)
    }

    @Test func noSubjectAnywhereKeepsTheSharpest() {
        let frames = [
            AimBurst.Frame(box: nil, sharpness: 10),
            AimBurst.Frame(box: nil, sharpness: 90),
            AimBurst.Frame(box: nil, sharpness: 30),
        ]
        #expect(AimBurst.pick(frames, framing: .whole) == 1)
        #expect(AimBurst.pick([], framing: .whole) == nil)
    }
}

// MARK: - Crop

struct AimBurstCropTests {
    private let portrait = CGSize(width: 3024, height: 4032)

    @Test func wellFramedIsLeftAlone() {
        #expect(AimBurst.crop(box: rect(midX: 0.52, midY: 0.5, w: 0.5, h: 0.4),
                              imageSize: portrait, framing: .whole) == nil)
    }

    @Test func smallObjectIsCenteredWithPadding() throws {
        let box = rect(midX: 0.3, midY: 0.6, w: 0.25, h: 0.2)
        let c = try #require(AimBurst.crop(box: box, imageSize: portrait, framing: .whole))
        // Same aspect as the photo.
        #expect(abs(c.width / c.height - 0.75) < 0.01)
        // Subject fills about half the crop in its limiting dimension.
        let fill = max(box.width * portrait.width / c.width, box.height * portrait.height / c.height)
        #expect(abs(fill - 0.5) < 0.02)
        // Subject centered.
        #expect(abs((box.midX * portrait.width - c.minX) / c.width - 0.5) < 0.01)
        #expect(abs((box.midY * portrait.height - c.minY) / c.height - 0.5) < 0.01)
        #expect(max(c.width, c.height) >= AimBurst.minLongSide)
    }

    @Test func tinySubjectStillKeepsTwoThousandPixels() throws {
        let box = rect(midX: 0.5, midY: 0.5, w: 0.05, h: 0.05)
        let c = try #require(AimBurst.crop(box: box, imageSize: portrait, framing: .whole))
        #expect(max(c.width, c.height) >= 2000)
        #expect(max(c.width, c.height) <= 2002)
    }

    @Test func smallPhotoIsNeverCropped() {
        #expect(AimBurst.crop(box: rect(midX: 0.3, midY: 0.3, w: 0.1, h: 0.1),
                              imageSize: CGSize(width: 1440, height: 1920), framing: .whole) == nil)
    }

    @Test func subjectNearEdgeStaysInsideAndInFrame() throws {
        let box = CGRect(x: 0.02, y: 0.85, width: 0.2, height: 0.13)
        let c = try #require(AimBurst.crop(box: box, imageSize: portrait, framing: .whole))
        #expect(CGRect(origin: .zero, size: portrait).contains(c))
        let subject = CGRect(x: box.minX * portrait.width, y: box.minY * portrait.height,
                             width: box.width * portrait.width, height: box.height * portrait.height)
        #expect(c.contains(subject))
    }

    @Test func faceGoesInTheUpperThird() throws {
        let box = rect(midX: 0.6, midY: 0.6, w: 0.12, h: 0.1)
        let c = try #require(AimBurst.crop(box: box, imageSize: portrait, framing: .person))
        #expect(abs((box.midY * portrait.height - c.minY) / c.height - 1.0 / 3.0) < 0.01)
        #expect(abs((box.midX * portrait.width - c.minX) / c.width - 0.5) < 0.01)
    }

    @Test func cutOffOrHugeSubjectIsNotCropped() {
        #expect(AimBurst.crop(box: CGRect(x: 0, y: 0.3, width: 0.3, height: 0.3),
                              imageSize: portrait, framing: .whole) == nil)
        #expect(AimBurst.crop(box: rect(midX: 0.3, midY: 0.5, w: 0.7, h: 0.3),
                              imageSize: portrait, framing: .whole) == nil)
    }
}
