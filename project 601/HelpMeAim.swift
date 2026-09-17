import CoreGraphics
import Foundation

// MARK: - Help Me Aim: the pure part
//
// "Help Me Aim" talks a blind photographer into the shot and then takes it.
// Dennis Long asked for it by name ("I'm trying to replicate the pixel", i.e.
// Google's Pixel Guided Frame, 2026-09-15), Amrit on AppleVis asked for the
// same thing, and the AppleVis threads on selfie apps set the rules this file
// follows: the countdown is said once, a person's face sits in the upper part
// of the frame unless it is a close-up, and guidance has to survive leaving
// the app and coming back.
//
// The person says WHAT they want a picture of first, so the app never guesses
// a subject (the rule from the first aim-assist design still holds).
//
// Everything in this file is arithmetic on boxes that were already measured,
// so it is unit tested without a camera. Boxes are normalized to the upright
// frame with the origin at the TOP-LEFT and y growing downward.

/// What the person asked for.
enum AimSubject: Equatable {
    case face
    case page
    case object(AimVocabulary.Match)

    /// "a face", "a picture or page", "a key".
    var spokenName: String {
        switch self {
        case .face: "a face"
        case .page: "a picture or page"
        case let .object(match): AimVocabulary.withArticle(match.spokenName)
        }
    }

    var framing: AimSteering.Framing {
        self == .face ? .person : .whole
    }
}

/// One thing the coach can tell the person.
enum AimInstruction: Equatable {
    case notFound
    case moveLeft, moveRight, moveUp, moveDown
    case moveCloser, backUp
    case framed
}

// MARK: - Steering

enum AimSteering {
    enum Framing {
        /// Faces and people: upper third, horizontally centered, unless the
        /// face fills the shot (then centered). A photographer's rule, raised
        /// on AppleVis ("Taking professional photos", 2023): "centered" is the
        /// wrong target for a person.
        case person
        /// Objects, pictures and pages: centered and not cut off at any edge.
        case whole
    }

    // Round 2 (Matt's field test, 2026-09-16: shot about 1 in 30 tries and
    // chattered): the good-enough zone is roughly the middle half of the
    // frame, "cut off" means really touching the edge, and "move closer" is
    // only for a subject that is tiny. The shot is taken wide and cropped
    // afterwards (AimBurst.crop), so the live framing can be generous.

    // Person framing.
    static let personTolerance: CGFloat = 0.22
    static let personLooseTolerance: CGFloat = 0.32
    static let upperThird: CGFloat = 1.0 / 3.0
    /// Below this face height the face goes in the upper third...
    static let closeUpStart: CGFloat = 0.30
    /// ...above this it is a close-up and goes in the middle.
    static let closeUpFull: CGFloat = 0.40
    static let personTooSmall: CGFloat = 0.08
    static let personLooseTooSmall: CGFloat = 0.06
    static let personTooBig: CGFloat = 0.75
    static let personLooseTooBig: CGFloat = 0.85

    // Whole-object framing.
    static let wholeTolerance: CGFloat = 0.25
    static let wholeLooseTolerance: CGFloat = 0.33
    /// A box edge this close to the frame edge is cut off.
    static let edgeMargin: CGFloat = 0.005
    static let looseEdgeMargin: CGFloat = 0.001
    static let wholeTooSmall: CGFloat = 0.10
    static let wholeLooseTooSmall: CGFloat = 0.08
    static let wholeTooBig: CGFloat = 0.97

    /// What to tell the person for this box. `loose` is the much wider zone
    /// used once "got it" has been said and while the countdown runs, so a
    /// hand's normal wobble does not undo it.
    static func instruction(for box: CGRect?, framing: Framing, loose: Bool = false) -> AimInstruction {
        guard let b = box, b.width > 0, b.height > 0 else { return .notFound }
        switch framing {
        case .person: return personInstruction(b, loose: loose)
        case .whole: return wholeInstruction(b, loose: loose)
        }
    }

    /// Where the middle of the subject belongs.
    static func target(for box: CGRect, framing: Framing) -> CGPoint {
        guard framing == .person else { return CGPoint(x: 0.5, y: 0.5) }
        if box.height > closeUpFull { return CGPoint(x: 0.5, y: 0.5) }
        if box.height < closeUpStart { return CGPoint(x: 0.5, y: upperThird) }
        // In between: slide from the upper third to the middle.
        let t = (box.height - closeUpStart) / (closeUpFull - closeUpStart)
        return CGPoint(x: 0.5, y: upperThird + (0.5 - upperThird) * t)
    }

    static func isCutOff(_ b: CGRect, margin: CGFloat = edgeMargin) -> Bool {
        b.minX < margin || b.minY < margin || b.maxX > 1 - margin || b.maxY > 1 - margin
    }

    private static func personInstruction(_ b: CGRect, loose: Bool) -> AimInstruction {
        let tol = loose ? personLooseTolerance : personTolerance
        let size = max(b.width, b.height)
        if size > (loose ? personLooseTooBig : personTooBig) { return .backUp }

        // Face really running off an edge: fix that first.
        let m = loose ? looseEdgeMargin : edgeMargin
        if b.minY < m { return .moveUp }
        if b.maxY > 1 - m { return .moveDown }
        if b.minX < m { return .moveLeft }
        if b.maxX > 1 - m { return .moveRight }

        // Top-to-bottom: upper third for a small face, middle for a close-up,
        // either in between.
        let low: CGFloat
        let high: CGFloat
        if b.height < closeUpStart {
            low = upperThird - tol; high = upperThird + tol
        } else if b.height > closeUpFull {
            low = 0.5 - tol; high = 0.5 + tol
        } else {
            low = upperThird - tol; high = 0.5 + tol
        }
        let dx = b.midX - 0.5
        let xOff = max(0, abs(dx) - tol)
        let yOff: CGFloat = b.midY < low ? low - b.midY : (b.midY > high ? b.midY - high : 0)
        if xOff > 0 || yOff > 0 {
            if xOff >= yOff { return dx < 0 ? .moveLeft : .moveRight }
            return b.midY < low ? .moveUp : .moveDown
        }
        if size < (loose ? personLooseTooSmall : personTooSmall) { return .moveCloser }
        return .framed
    }

    private static func wholeInstruction(_ b: CGRect, loose: Bool) -> AimInstruction {
        let m = loose ? looseEdgeMargin : edgeMargin
        let cutL = b.minX < m, cutR = b.maxX > 1 - m
        let cutT = b.minY < m, cutB = b.maxY > 1 - m
        if (cutL && cutR) || (cutT && cutB) || b.width > wholeTooBig || b.height > wholeTooBig {
            return .backUp
        }
        // One edge cut off: move toward it and the rest comes into the picture.
        if cutL { return .moveLeft }
        if cutR { return .moveRight }
        if cutT { return .moveUp }
        if cutB { return .moveDown }

        let tol = loose ? wholeLooseTolerance : wholeTolerance
        let dx = b.midX - 0.5, dy = b.midY - 0.5
        let xOff = max(0, abs(dx) - tol), yOff = max(0, abs(dy) - tol)
        if xOff > 0 || yOff > 0 {
            if xOff >= yOff { return dx < 0 ? .moveLeft : .moveRight }
            return dy < 0 ? .moveUp : .moveDown
        }
        if max(b.width, b.height) < (loose ? wholeLooseTooSmall : wholeTooSmall) { return .moveCloser }
        return .framed
    }

    /// Turns a box measured in the portrait camera buffer into the frame the
    /// person is actually holding, `quarterTurns` × 90° clockwise. Needed so
    /// "move the phone up" still means up when the phone is held sideways.
    static func rotateClockwise(_ box: CGRect, quarterTurns: Int) -> CGRect {
        var b = box
        for _ in 0 ..< (((quarterTurns % 4) + 4) % 4) {
            // (x, y) -> (1 - y, x) for each point.
            b = CGRect(x: 1 - b.maxY, y: b.minX, width: b.height, height: b.width)
        }
        return b
    }

    /// Extra clockwise quarter turns to apply to a buffer that is already
    /// rotated to portrait (90°), given the level-shot angle the rotation
    /// coordinator reports for how the phone is held.
    static func quarterTurns(levelAngle: CGFloat) -> Int {
        let q = Int(((levelAngle - 90) / 90).rounded())
        return ((q % 4) + 4) % 4
    }
}

// MARK: - Phrases

enum AimPhrases {
    static func phrase(for instruction: AimInstruction, subject: AimSubject, faceCount: Int = 1) -> String {
        switch instruction {
        case .notFound: "I don't see \(subject.spokenName) yet, move the phone slowly"
        case .moveLeft: "move the phone left"
        case .moveRight: "move the phone right"
        case .moveUp: "move the phone up"
        case .moveDown: "move the phone down"
        case .moveCloser: "move closer"
        case .backUp: "back up"
        case .framed:
            if subject == .face, faceCount > 1 {
                "got it, \(countWord(faceCount)) faces, hold still"
            } else {
                "got it, hold still"
            }
        }
    }

    static func intro(for subject: AimSubject) -> String {
        "Looking for \(subject.spokenName). Move the phone slowly. Double tap anywhere to take the picture yourself."
    }

    static let lostIt = "lost it"
    static let pictureTaken = "picture taken"
    static let savedSuffix = ", saved to your photos"
    static let notSavedSuffix = ", but I couldn't save it. Allow adding photos in Settings"
    static let captureFailed = "I couldn't take the picture, try again"
    // Something Else, round 2 (Matt: "you don't know when to speak, if you
    // need to press the button, or hold it"). The app asks, beeps, and
    // listens by itself; Speak is a single tap for a retry.
    static let askWhat = "After the beep, say what you're looking for."
    static let heardNothing = "I didn't hear anything. Tap Speak to try again, or type it."
    static let didntCatch = "I didn't catch that. Tap Speak to try again."
    static let speakLabel = "Speak, tap once, then say what you're looking for after the beep"
    static let countdown = ["3", "2", "1"]

    static func cantLookFor(_ word: String) -> String {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        return w.isEmpty ? didntCatch : "I can't look for \(w) yet"
    }

    static func countWord(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return n >= 0 && n < words.count ? words[n] : "many"
    }

    static func capitalized(_ s: String) -> String {
        guard let head = s.first else { return s }
        return head.uppercased() + s.dropFirst()
    }
}

// MARK: - Listening timing and tones

enum AimListening {
    /// Wait this long after the prompt has finished before the beep, so the
    /// microphone does not catch the tail of the sentence.
    static let afterPrompt: TimeInterval = 0.4
    /// Stop this long after the last new word.
    static let silence: TimeInterval = 1.3
    /// Nothing heard at all by then: give up.
    static let noSpeech: TimeInterval = 6.0
    /// Hard stop.
    static let maxTotal: TimeInterval = 9.0

    enum Result: Equatable { case heard(String), silence, notUnderstood }

    static func shouldStop(heardSomething: Bool, quiet: TimeInterval, total: TimeInterval) -> Bool {
        if total >= maxTotal { return true }
        return heardSomething ? quiet >= silence : total >= noSpeech
    }

    static func result(transcript: String, failed: Bool) -> Result {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return .heard(t) }
        return failed ? .notUnderstood : .silence
    }

    /// What to say for a listening result that did not become a search.
    static func reply(for result: Result) -> String? {
        switch result {
        case .heard: nil
        case .silence: AimPhrases.heardNothing
        case .notUnderstood: AimPhrases.didntCatch
        }
    }
}

/// Short generated beeps, so there is no doubt when to talk: two rising
/// notes to start, two falling notes when listening stops.
enum AimTones {
    static let start: [Double] = [660, 990]
    static let end: [Double] = [990, 660]
    static let noteSeconds = 0.09
    static let sampleRate = 44_100

    static var duration: TimeInterval { noteSeconds * Double(start.count) }

    /// 16-bit mono PCM WAV with a short fade on every note (no clicks).
    static func wav(_ notes: [Double], noteSeconds: Double = noteSeconds, volume: Double = 0.6) -> Data {
        let perNote = Int(Double(sampleRate) * noteSeconds)
        let fade = max(1, perNote / 8)
        var samples: [Int16] = []
        samples.reserveCapacity(perNote * notes.count)
        for f in notes {
            for i in 0 ..< perNote {
                let env = min(1, Double(min(i, perNote - 1 - i)) / Double(fade))
                let v = sin(2 * Double.pi * f * Double(i) / Double(sampleRate)) * volume * env
                samples.append(Int16(max(-1, min(1, v)) * Double(Int16.max)))
            }
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }
}

// MARK: - Coach (the state machine between the detector and the voice)

/// Fed one observation per analysed frame; decides what to say, when the
/// countdown starts and when it is cancelled. No clocks or speech inside, so
/// the whole behaviour is testable.
///
/// Round 2 rules (Matt's field test): judge a median of the last few boxes,
/// not the raw jittery one; a new steering instruction must hold for half a
/// second before it is spoken (no left/right flip-flop); once "got it" is
/// said the subject stays framed until it has been outside a much looser
/// zone for 0.7 s; and the countdown starts after the zone has simply been
/// held for 0.4 s (the old 5% drift rule was smaller than detector jitter).
struct AimCoach {
    enum Haptic: Equatable { case none, tick, success, warning }

    enum Action: Equatable {
        case say(String, Haptic)
        case startCountdown
        case cancelCountdown
    }

    let subject: AimSubject

    /// Same sentence again no sooner than this.
    var repeatInterval: TimeInterval = 2.5
    /// Gap after any sentence before a different one.
    var minGap: TimeInterval = 0.8
    /// "I don't see it yet" after this long with nothing found (Matt: 5 s,
    /// 3 s was too eager)...
    var notFoundAfter: TimeInterval = 5.0
    /// ...and then no more often than this.
    var notFoundRepeat: TimeInterval = 6.0
    /// After this long still not found, say what IS in view instead
    /// ("I don't see a key. I can see a dog and a laptop.")...
    var elsewhereAfter: TimeInterval = 15.0
    /// ...at most this often...
    var elsewhereRepeat: TimeInterval = 20.0
    /// ...and not closer than this to the previous "I don't see" line.
    var elsewhereGap: TimeInterval = 3.0
    /// A box that blinks out for less than this still counts as there.
    var holdLastBox: TimeInterval = 0.6
    /// A new steering instruction must stay the same this long to be spoken.
    var settle: TimeInterval = 0.5
    /// Framed must hold this long before "got it".
    var framedSettle: TimeInterval = 0.3
    /// After "got it", the zone held this long starts the countdown.
    var steadyFor: TimeInterval = 0.4
    /// Moving more than this (share of the frame) restarts the steady clock.
    var steadyDrift: CGFloat = 0.15
    /// Outside the loose zone this long undoes "got it" / cancels the countdown.
    var leaveAfter: TimeInterval = 0.7
    /// Boxes in the median.
    var smoothingWindow = 5

    private(set) var isCountingDown = false
    private(set) var isLocked = false
    private(set) var smoothedBox: CGRect?
    private var recent: [(at: Date, box: CGRect)] = []
    private var lastSeen: Date?
    private var startedAt: Date?
    private var lastPhrase: String?
    private var lastSpokenAt = Date.distantPast
    /// Last "I don't see…" line of either kind, and of the long kind.
    private var lastMissAt = Date.distantPast
    private var lastElsewhereAt = Date.distantPast
    private var candidate: AimInstruction?
    private var candidateSince = Date.distantPast
    private var lockedAt = Date.distantPast
    private var anchor: CGPoint?
    private var outSince: Date?

    init(subject: AimSubject) {
        self.subject = subject
    }

    /// Start over (a new aim, or back from the background).
    mutating func reset(now: Date) {
        countdownEnded()
        smoothedBox = nil
        recent = []
        lastSeen = nil
        startedAt = now
        lastPhrase = nil
        lastSpokenAt = .distantPast
        lastMissAt = .distantPast
        lastElsewhereAt = .distantPast
    }

    /// The controller cancelled or finished the countdown itself. "Got it"
    /// has to be earned again, not said on the very next frame.
    mutating func countdownEnded() {
        isCountingDown = false
        isLocked = false
        anchor = nil
        outSince = nil
        candidate = nil
        candidateSince = .distantPast
    }

    /// `elsewhere` is the ready "I don't see X. I can see …" sentence for this
    /// frame, or nil when nothing else was looked for (faces).
    mutating func observe(box raw: CGRect?, faceCount: Int = 1, now: Date, voiceBusy: Bool,
                          elsewhere: String? = nil) -> [Action] {
        if startedAt == nil { startedAt = now }
        let box = track(raw, now: now)
        let inLooseZone = AimSteering.instruction(for: box, framing: subject.framing, loose: true) == .framed

        if isCountingDown {
            if inLooseZone { outSince = nil; return [] }
            let since = outSince ?? now
            outSince = since
            guard now.timeIntervalSince(since) + 1e-6 >= leaveAfter else { return [] }
            countdownEnded()
            lastPhrase = AimPhrases.lostIt
            lastSpokenAt = now
            return [.cancelCountdown, .say(AimPhrases.lostIt, .warning)]
        }

        if isLocked {
            if inLooseZone, let b = box {
                outSince = nil
                let center = CGPoint(x: b.midX, y: b.midY)
                if let a = anchor, hypot(center.x - a.x, center.y - a.y) <= steadyDrift {
                    if raw != nil, !voiceBusy, now.timeIntervalSince(lockedAt) + 1e-6 >= steadyFor {
                        isCountingDown = true
                        return [.startCountdown]
                    }
                } else {
                    anchor = center
                    lockedAt = now
                }
                return []
            }
            let since = outSince ?? now
            outSince = since
            guard now.timeIntervalSince(since) + 1e-6 >= leaveAfter else { return [] }
            // Really gone: back to steering.
            countdownEnded()
        }

        let instruction = AimSteering.instruction(for: box, framing: subject.framing)
        if instruction != candidate {
            candidate = instruction
            candidateSince = now
        }

        if instruction == .notFound {
            let since = lastSeen ?? startedAt ?? now
            let lost = now.timeIntervalSince(since) + 1e-6
            guard lost >= notFoundAfter else { return [] }
            let quiet = now.timeIntervalSince(lastSpokenAt) + 1e-6
            if voiceBusy || quiet < minGap { return [] }
            let sinceMiss = now.timeIntervalSince(lastMissAt) + 1e-6
            let text: String
            if let elsewhere, lost >= elsewhereAfter, sinceMiss >= elsewhereGap,
               now.timeIntervalSince(lastElsewhereAt) + 1e-6 >= elsewhereRepeat {
                text = elsewhere
                lastElsewhereAt = now
            } else if sinceMiss >= notFoundRepeat {
                text = AimPhrases.phrase(for: .notFound, subject: subject)
            } else {
                return []
            }
            lastMissAt = now
            lastPhrase = text
            lastSpokenAt = now
            return [.say(text, .none)]
        } else {
            let wait = instruction == .framed ? framedSettle : settle
            guard now.timeIntervalSince(candidateSince) + 1e-6 >= wait else { return [] }
        }

        let quiet = now.timeIntervalSince(lastSpokenAt) + 1e-6
        if voiceBusy || quiet < minGap { return [] }

        if instruction == .framed, let b = box {
            let text = AimPhrases.phrase(for: .framed, subject: subject, faceCount: faceCount)
            isLocked = true
            lockedAt = now // the steady clock starts after the sentence begins
            anchor = CGPoint(x: b.midX, y: b.midY)
            outSince = nil
            lastPhrase = text
            lastSpokenAt = now
            return [.say(text, .success)]
        }

        let text = AimPhrases.phrase(for: instruction, subject: subject, faceCount: faceCount)
        if text == lastPhrase, quiet < repeatInterval { return [] }
        lastPhrase = text
        lastSpokenAt = now
        return [.say(text, .tick)]
    }

    /// Median of the last few boxes (per edge), so detector jitter and hand
    /// shake do not flip the instruction; a short dropout keeps the last box.
    private mutating func track(_ raw: CGRect?, now: Date) -> CGRect? {
        if let raw {
            lastSeen = now
            recent.append((now, raw))
            recent.removeAll { now.timeIntervalSince($0.at) > 1.0 }
            if recent.count > smoothingWindow { recent.removeFirst(recent.count - smoothingWindow) }
            smoothedBox = AimCoach.median(recent.map(\.box))
            return smoothedBox
        }
        if let seen = lastSeen, now.timeIntervalSince(seen) <= holdLastBox + 1e-6 {
            return smoothedBox
        }
        recent = []
        smoothedBox = nil
        return nil
    }

    static func median(_ boxes: [CGRect]) -> CGRect? {
        guard !boxes.isEmpty else { return nil }
        func mid(_ values: [CGFloat]) -> CGFloat {
            let s = values.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        let minX = mid(boxes.map(\.minX)), minY = mid(boxes.map(\.minY))
        let maxX = mid(boxes.map(\.maxX)), maxY = mid(boxes.map(\.maxY))
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}

// MARK: - Burst pick and crop

/// Round 2: the countdown ends in a short burst; the detector runs on every
/// frame and the best-framed one is kept, then cropped so the subject sits
/// where a photographer would put it ("shoot wide, crop after").
enum AimBurst {
    struct Frame: Equatable {
        /// Subject box, normalized, top-left origin, upright photo.
        var box: CGRect?
        /// Variance of Laplacian from FrameQualityGate (higher is sharper).
        var sharpness: Double
    }

    /// Sharpness above this earns no more credit.
    static let sharpnessCap: Double = 300
    static let sharpnessWeight: Double = 0.3
    static let cutOffPenalty: Double = 1.0

    /// Higher is better; nil when the subject is not in the frame.
    /// 1 − 2 × (distance from the framing target) − 1 if cut off
    ///   + 0.3 × min(sharpness, 300) / 300.
    static func score(_ f: Frame, framing: AimSteering.Framing) -> Double? {
        guard let b = f.box, b.width > 0, b.height > 0 else { return nil }
        let t = AimSteering.target(for: b, framing: framing)
        let distance = Double(hypot(b.midX - t.x, b.midY - t.y))
        var s = 1 - 2 * distance
        if AimSteering.isCutOff(b) { s -= cutOffPenalty }
        s += sharpnessWeight * min(max(f.sharpness, 0), sharpnessCap) / sharpnessCap
        return s
    }

    /// Index of the frame to keep: the best score, or the sharpest frame if
    /// the subject is in none of them. Nil only for an empty burst.
    static func pick(_ frames: [Frame], framing: AimSteering.Framing) -> Int? {
        guard !frames.isEmpty else { return nil }
        let scored = frames.enumerated().compactMap { i, f in score(f, framing: framing).map { (i, $0) } }
        if let best = scored.max(by: { $0.1 < $1.1 }) { return best.0 }
        return frames.enumerated().max { $0.element.sharpness < $1.element.sharpness }?.offset
    }

    /// Never crop to less than this on the long side.
    static let minLongSide: CGFloat = 2000
    /// Share of the crop the subject should fill (its bigger dimension):
    /// objects about half (25% padding each side), a face about a third so
    /// there is room for shoulders.
    static let objectFill: CGFloat = 0.5
    static let faceFill: CGFloat = 0.35
    /// Already this close to the target and at least this big: leave it.
    static let wellFramedDistance: CGFloat = 0.08
    static let wellFramedSize: CGFloat = 0.4

    /// The crop rectangle in pixels (top-left origin), or nil to keep the
    /// whole photo. Same aspect ratio as the photo.
    static func crop(box: CGRect, imageSize: CGSize, framing: AimSteering.Framing) -> CGRect? {
        let W = imageSize.width, H = imageSize.height
        guard W > 0, H > 0, box.width > 0, box.height > 0, max(W, H) > minLongSide else { return nil }
        // Subject cut off in the photo: cropping cannot bring it back.
        guard !AimSteering.isCutOff(box) else { return nil }
        let t = AimSteering.target(for: box, framing: framing)
        let size = max(box.width, box.height)
        if hypot(box.midX - t.x, box.midY - t.y) <= wellFramedDistance, size >= wellFramedSize { return nil }

        let fill = framing == .person && box.height < AimSteering.closeUpFull ? faceFill : objectFill
        let aspect = W / H
        let bw = box.width * W, bh = box.height * H
        var cw = max(bw / fill, (bh / fill) * aspect)
        var ch = cw / aspect
        // Keep enough pixels.
        let long = max(cw, ch)
        if long < minLongSide {
            let k = minLongSide / long
            cw *= k; ch *= k
        }
        guard cw < W * 0.98, ch < H * 0.98 else { return nil }

        // Put the subject's middle at the target point, then keep inside the photo.
        var x = box.midX * W - t.x * cw
        var y = box.midY * H - t.y * ch
        x = min(max(0, x), W - cw)
        y = min(max(0, y), H - ch)
        let rect = CGRect(x: x, y: y, width: cw, height: ch).integral
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        let subject = CGRect(x: box.minX * W, y: box.minY * H, width: bw, height: bh)
        guard rect.contains(subject.insetBy(dx: 1, dy: 1)) else { return nil }
        return rect
    }
}

// MARK: - What else is in view

/// Builds "I don't see a key. I can see a dog, a laptop and a mirror." from
/// the YOLOE detections already running on each frame (Matt, 2026-09-16).
/// The room scan showed YOLOE also names rooms and genres with high
/// confidence ("home interior", "tv genre"), so those are filtered out.
enum AimElsewhere {
    struct Seen: Equatable {
        var name: String
        var conf: Float
        var box: CGRect
    }

    static let minConf: Float = 0.60
    static let minFrames = 2
    static let window = 5
    static let maxThings = 3

    /// Whole names never worth saying.
    static let denylist: Set<String> = [
        "home interior", "playroom", "veterinarians office", "hospital room", "tv genre", "waste",
        "garment", "organization", "floor", "ceiling", "wall", "doorway", "mess", "indoor", "decor",
        "home decor", "collection", "lighting", "comfort", "clothe", "electronic", "fixture", "touch",
        "control", "electricity", "type on", "navratri", "quote", "news", "poetry", "illustration",
        "icon", "oval", "grid", "cube", "swirl", "shadow", "twist", "contain", "bundle", "stack",
        "article", "publication", "character sculpture", "fashion illustration", "line art",
        "studio shot", "car logo", "inscription", "plaid", "velvet", "cotton", "khaki", "granite",
        "beam", "navy", "hospital", "laboratory", "salon", "workplace", "pantry", "alcove", "mantle",
        "entrance hall", "living space", "dressing room", "childs room", "recreation room", "embellishment",
        "animation film", "science fiction film", "firework display", "light show", "wedding reception",
        "art exhibition", "street scene", "hairstyle", "manicure", "pigtail", "braid", "toe", "waist",
        "ear", "hand", "face", "beard", "tail", "claw", "flash", "pad", "capsule", "recycling",
    ]

    /// Parts of names that mean a place, a genre or a scene.
    static let deniedFragments = [
        "room", "interior", "office", "genre", "scene", "film", "drama", "studio", "classroom",
        "gym", "shop", "store", "parlor", "mall", "library", "corridor", "hallway", "alley", "hall",
    ]

    /// Breeds and people-words said plainly.
    static let collapse: [String: String] = [
        "samoyed": "dog", "poodle": "dog", "bichon": "dog", "golden retriever": "dog",
        "german shepherd": "dog", "rottweiler": "dog", "chihuahua": "dog", "sheepdog": "dog",
        "pomeranian": "dog", "street dog": "dog", "labrador retriever": "dog", "labrador": "dog",
        "beagle": "dog", "pug": "dog", "dachshund": "dog", "husky": "dog", "puppy": "dog",
        "guide dog": "dog", "pet": "dog",
        "persian cat": "cat", "american shorthair": "cat", "siamese cat": "cat", "kitten": "cat",
        "tabby cat": "cat", "ragdoll": "cat", "maine coon": "cat",
        "man": "person", "woman": "person", "girl": "person", "boy": "person",
        "grandfather": "person", "grandmother": "person", "cousin": "person", "daughter": "person",
        "son": "person", "newlywed": "person", "college student": "person", "patient": "person",
        "researcher": "person", "hacker": "person", "technician": "person", "historian": "person",
        "dentist": "person", "fashion designer": "person", "child": "person", "baby": "person",
        "shelve": "shelf", "clothe": "clothes",
    ]

    /// Names said without "a"/"an".
    static let noArticle: Set<String> = [
        "glasses", "sunglasses", "jeans", "shorts", "goggles", "scissors", "headphones", "pants",
        "underdrawers", "clothes", "money", "laundry", "bedding", "linen", "detergent", "duct tape",
    ]

    /// The name to say, or nil if the class should never be mentioned.
    static func spokenName(_ cls: String) -> String? {
        let name = cls.lowercased().trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !denylist.contains(name) else { return nil }
        if let plain = collapse[name] { return plain }
        if deniedFragments.contains(where: { name.contains($0) }) { return nil }
        return name
    }

    static func article(_ name: String) -> String {
        noArticle.contains(name) ? name : AimVocabulary.withArticle(name)
    }

    /// Overlapping boxes (IoU > 0.5) keep only the most confident one.
    static func dedupe(_ frame: [Seen]) -> [Seen] {
        var kept: [Seen] = []
        for s in frame.sorted(by: { $0.conf > $1.conf }) where !kept.contains(where: { iou($0.box, s.box) > 0.5 }) {
            kept.append(s)
        }
        return kept
    }

    /// Up to three things, most confident first: said name, confidence at
    /// least 0.60, in at least two of the recent frames, not the target.
    static func pick(_ frames: [[Seen]], excluding target: Set<String>) -> [String] {
        var best: [String: Float] = [:]
        var count: [String: Int] = [:]
        for frame in frames.suffix(window) {
            var inFrame: Set<String> = []
            for s in dedupe(frame.filter { $0.conf >= minConf }) {
                guard let name = spokenName(s.name), !target.contains(name) else { continue }
                best[name] = max(best[name] ?? 0, s.conf)
                inFrame.insert(name)
            }
            for name in inFrame { count[name, default: 0] += 1 }
        }
        return best.filter { (count[$0.key] ?? 0) >= minFrames }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxThings)
            .map(\.key)
    }

    static func sentence(subject: AimSubject, things: [String]) -> String {
        let missing = subject.spokenName
        guard !things.isEmpty else {
            return "I don't see \(missing), and nothing else stands out. Try another direction."
        }
        let said = things.map(article)
        let list: String = switch said.count {
        case 1: said[0]
        case 2: "\(said[0]) and \(said[1])"
        default: said.dropLast().joined(separator: ", ") + " and " + said[said.count - 1]
        }
        return "I don't see \(missing). I can see \(list)."
    }

    /// Names that count as the target itself (so a dog is not offered when
    /// looking for a dog).
    static func targetNames(for subject: AimSubject) -> Set<String> {
        switch subject {
        case .face: return ["person", "face"]
        case .page: return ["document", "paper", "picture", "photo", "picture frame", "photo frame", "poster"]
        case let .object(m):
            return Set(([m.spokenName] + m.classNames).map { spokenName($0) ?? $0.lowercased() })
        }
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }
}

// MARK: - Spoken word -> YOLOE class

enum AimVocabulary {
    struct Match: Equatable {
        /// What we say back: the word as the person meant it ("key").
        var spokenName: String
        /// Every model class that counts as that thing.
        var classNames: [String]
        var classIDs: [Int32]
    }

    /// Spoken words that the model knows under other names. Only names that
    /// really exist in the vocabulary are kept at lookup time, so an entry
    /// here can never invent a class ("wallet" has none today).
    static let synonyms: [String: [String]] = [
        "wallet": ["wallet", "purse"],
        "purse": ["purse", "handbag"],
        "painting": ["oil painting", "watercolor painting", "picture frame", "photo frame", "poster", "painting"],
        "picture": ["picture frame", "photo frame", "poster", "picture", "photo"],
        "photo": ["photo frame", "picture frame", "photo"],
        "photograph": ["photo frame", "picture frame", "photo"],
        "phone": ["phone", "smartphone", "iphone"],
        "cell phone": ["phone", "smartphone", "iphone"],
        "cellphone": ["phone", "smartphone", "iphone"],
        "mobile phone": ["phone", "smartphone", "iphone"],
        "smartphone": ["smartphone", "phone", "iphone"],
        "iphone": ["iphone", "smartphone", "phone"],
        "remote": ["remote", "remote control"],
        "remote control": ["remote", "remote control"],
        "tv remote": ["remote", "remote control"],
        "tv": ["television"],
        "telly": ["television"],
        "sofa": ["couch"],
        "cup": ["cup", "mug", "coffee cup"],
        "mug": ["mug", "cup", "coffee cup"],
        "coffee mug": ["mug", "coffee cup", "cup"],
        "guide dog": ["dog"],
        "puppy": ["puppy", "dog"],
        "kitten": ["kitten", "cat"],
        "car key": ["key"],
        "house key": ["key"],
        "key ring": ["key"],
        "keyring": ["key"],
        "eyeglasses": ["glasses"],
        "spectacles": ["glasses"],
        "reading glasses": ["glasses"],
        "bag": ["bag", "handbag", "backpack"],
        "pills": ["medicine", "pill"],
        "pill bottle": ["medicine", "pill"],
        "mail": ["letter", "envelope"],
        "bill": ["document", "paper", "letter"],
        "page": ["document", "paper"],
        "person": ["person"],
        "me": ["person", "face"],
        "myself": ["person", "face"],
    ]

    private static let prepositions: Set<String> = [
        "to", "of", "for", "on", "in", "with", "from", "at", "by", "near", "under", "behind",
    ]

    private static let fillers = [
        "i'm looking for ", "im looking for ", "i am looking for ", "looking for ",
        "i want ", "find my ", "find the ", "find ", "where is my ", "where's my ",
        "a picture of ", "picture of my ", "picture of ",
        "my ", "the ", "a ", "an ", "some ", "our ",
    ]

    /// The vocabulary, lower-cased, with every index a name appears at.
    static func index(_ classNames: [String]) -> [String: [Int32]] {
        var out: [String: [Int32]] = [:]
        for (i, name) in classNames.enumerated() {
            out[name.lowercased(), default: []].append(Int32(i))
        }
        return out
    }

    static func match(_ spoken: String, classNames: [String]) -> Match? {
        match(spoken, index: index(classNames))
    }

    static func match(_ spoken: String, index: [String: [Int32]]) -> Match? {
        let phrase = normalize(spoken)
        guard !phrase.isEmpty else { return nil }

        var tries: [String] = forms(of: phrase)
        // When the whole phrase is unknown, look for the thing itself: the
        // part before a preposition ("keys to the car" -> "keys"), then its
        // last word ("my red keys" -> "keys"). Not simply the first word that
        // is a class: "red", "black", "house" and "car" all are.
        let words = phrase.split(separator: " ").map(String.init)
        let head = Array(words.prefix { !prepositions.contains($0) })
        if !head.isEmpty, head.count < words.count {
            tries += forms(of: head.joined(separator: " "))
        }
        if let last = head.last ?? words.last, last != phrase {
            tries += forms(of: last)
        }

        for word in tries {
            var names: [String] = []
            for candidate in (synonyms[word] ?? []) + [word] where index[candidate] != nil {
                if !names.contains(candidate) { names.append(candidate) }
            }
            if !names.isEmpty {
                let ids = names.flatMap { index[$0] ?? [] }
                return Match(spokenName: word, classNames: names, classIDs: ids)
            }
        }
        return nil
    }

    /// The phrase itself, then singular guesses for it.
    static func forms(of phrase: String) -> [String] {
        var out = [phrase]
        func add(_ s: String) { if !s.isEmpty, !out.contains(s) { out.append(s) } }
        if phrase.hasSuffix("ies") { add(String(phrase.dropLast(3)) + "y") }
        if phrase.hasSuffix("ves") {
            add(String(phrase.dropLast(3)) + "f")
            add(String(phrase.dropLast(3)) + "fe")
        }
        if phrase.hasSuffix("es") { add(String(phrase.dropLast(2))) }
        if phrase.hasSuffix("s"), !phrase.hasSuffix("ss") { add(String(phrase.dropLast())) }
        return out
    }

    static func normalize(_ spoken: String) -> String {
        var s = spoken.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits)
                .union(CharacterSet(charactersIn: " '-")).inverted)
            .joined()
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        var changed = true
        while changed {
            changed = false
            for filler in fillers where s.hasPrefix(filler) && s.count > filler.count {
                s = String(s.dropFirst(filler.count))
                changed = true
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func withArticle(_ word: String) -> String {
        guard let first = word.lowercased().first else { return word }
        return ("aeiou".contains(first) ? "an " : "a ") + word
    }
}
