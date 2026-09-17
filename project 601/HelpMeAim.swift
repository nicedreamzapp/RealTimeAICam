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
    static let askWhat = "What are you looking for? Tap Speak, then say it, or type it."
    static let countdown = ["3", "2", "1"]

    static func cantLookFor(_ word: String) -> String {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        return w.isEmpty ? "I didn't catch that, try again" : "I can't look for \(w) yet"
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
    /// "I don't see it yet" after this long with nothing found...
    var notFoundAfter: TimeInterval = 3.0
    /// ...and then no more often than this.
    var notFoundRepeat: TimeInterval = 6.0
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

    mutating func observe(box raw: CGRect?, faceCount: Int = 1, now: Date, voiceBusy: Bool) -> [Action] {
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
            guard now.timeIntervalSince(since) + 1e-6 >= notFoundAfter else { return [] }
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
        let again = instruction == .notFound ? notFoundRepeat : repeatInterval
        if text == lastPhrase, quiet < again { return [] }
        lastPhrase = text
        lastSpokenAt = now
        return [.say(text, instruction == .notFound ? .none : .tick)]
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
