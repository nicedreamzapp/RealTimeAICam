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

    // Person framing. First guesses; tune on a phone.
    static let personTolerance: CGFloat = 0.12
    static let personLooseTolerance: CGFloat = 0.18
    static let upperThird: CGFloat = 1.0 / 3.0
    /// Below this face height the face goes in the upper third...
    static let closeUpStart: CGFloat = 0.30
    /// ...above this it is a close-up and goes in the middle.
    static let closeUpFull: CGFloat = 0.40
    static let personTooSmall: CGFloat = 0.15
    static let personTooBig: CGFloat = 0.65
    /// A face box this close to the top means the forehead is already gone.
    static let headroom: CGFloat = 0.04
    static let personSideMargin: CGFloat = 0.02

    // Whole-object framing.
    static let wholeTolerance: CGFloat = 0.15
    static let wholeLooseTolerance: CGFloat = 0.22
    static let edgeMargin: CGFloat = 0.02
    static let looseEdgeMargin: CGFloat = 0.005
    static let wholeTooSmall: CGFloat = 0.25
    static let wholeLooseTooSmall: CGFloat = 0.20
    static let wholeTooBig: CGFloat = 0.95

    /// What to tell the person for this box. `loose` is used while the
    /// countdown runs, so a hand's normal wobble does not cancel it.
    static func instruction(for box: CGRect?, framing: Framing, loose: Bool = false) -> AimInstruction {
        guard let b = box, b.width > 0, b.height > 0 else { return .notFound }
        switch framing {
        case .person: return personInstruction(b, loose: loose)
        case .whole: return wholeInstruction(b, loose: loose)
        }
    }

    private static func personInstruction(_ b: CGRect, loose: Bool) -> AimInstruction {
        let tol = loose ? personLooseTolerance : personTolerance
        let size = max(b.width, b.height)
        if size > (loose ? personTooBig + 0.07 : personTooBig) { return .backUp }

        // Part of the face already out of the picture: fix that first.
        let slack: CGFloat = loose ? 0.02 : 0
        if b.minY < headroom - slack { return .moveUp }
        if b.maxY > 1 - personSideMargin + slack { return .moveDown }
        if b.minX < personSideMargin - slack { return .moveLeft }
        if b.maxX > 1 - personSideMargin + slack { return .moveRight }

        // Where the middle of the face belongs, top to bottom.
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
        if size < (loose ? personTooSmall - 0.03 : personTooSmall) { return .moveCloser }
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
struct AimCoach {
    enum Haptic: Equatable { case none, tick, success, warning }

    enum Action: Equatable {
        case say(String, Haptic)
        case startCountdown
        case cancelCountdown
    }

    let subject: AimSubject

    /// Same sentence again no sooner than this.
    var repeatInterval: TimeInterval = 2.0
    /// Gap after any sentence before a different one.
    var minGap: TimeInterval = 0.8
    /// "I don't see it yet" after this long with nothing found...
    var notFoundAfter: TimeInterval = 3.0
    /// ...and then no more often than this.
    var notFoundRepeat: TimeInterval = 6.0
    /// A box that blinks out for less than this still counts as there.
    var holdLastBox: TimeInterval = 0.5
    /// Framed and steady this long starts the countdown.
    var steadyFor: TimeInterval = 0.5
    /// The subject moving more than this (share of the frame) is not steady.
    var steadyDrift: CGFloat = 0.05

    private(set) var isCountingDown = false
    private(set) var smoothedBox: CGRect?
    private var lastSeen: Date?
    private var startedAt: Date?
    private var lastPhrase: String?
    private var lastSpokenAt = Date.distantPast
    private var candidate: AimInstruction?
    private var candidateCount = 0
    private var framedSince: Date?
    private var framedAnchor: CGPoint?
    private var framedAnnounced = false
    private var countdownMisses = 0

    init(subject: AimSubject) {
        self.subject = subject
    }

    /// Start over (a new aim, or back from the background).
    mutating func reset(now: Date) {
        isCountingDown = false
        smoothedBox = nil
        lastSeen = nil
        startedAt = now
        lastPhrase = nil
        lastSpokenAt = .distantPast
        candidate = nil
        candidateCount = 0
        framedSince = nil
        framedAnchor = nil
        framedAnnounced = false
        countdownMisses = 0
    }

    /// The controller cancelled or finished the countdown itself.
    mutating func countdownEnded() {
        isCountingDown = false
        // A fresh round: "got it" has to be earned again, not said on the
        // very next frame after "picture taken" or "lost it".
        candidate = nil
        candidateCount = 0
        framedSince = nil
        framedAnchor = nil
        framedAnnounced = false
        countdownMisses = 0
    }

    mutating func observe(box raw: CGRect?, faceCount: Int = 1, now: Date, voiceBusy: Bool) -> [Action] {
        if startedAt == nil { startedAt = now }
        let box = track(raw, now: now)

        if isCountingDown {
            let still = AimSteering.instruction(for: box, framing: subject.framing, loose: true) == .framed
            countdownMisses = still ? 0 : countdownMisses + 1
            guard countdownMisses >= 2 else { return [] }
            countdownEnded()
            lastPhrase = AimPhrases.lostIt
            lastSpokenAt = now
            return [.cancelCountdown, .say(AimPhrases.lostIt, .warning)]
        }

        let instruction = AimSteering.instruction(for: box, framing: subject.framing)
        if instruction == .notFound {
            let since = lastSeen ?? startedAt ?? now
            if now.timeIntervalSince(since) < notFoundAfter { return [] }
        }

        // Debounce: a new instruction has to show up twice in a row.
        if instruction == candidate {
            candidateCount += 1
        } else {
            candidate = instruction
            candidateCount = 1
        }

        var actions: [Action] = []

        if instruction == .framed, let b = box {
            let center = CGPoint(x: b.midX, y: b.midY)
            if let anchor = framedAnchor,
               hypot(center.x - anchor.x, center.y - anchor.y) <= steadyDrift,
               let since = framedSince {
                if framedAnnounced, raw != nil, !voiceBusy, now.timeIntervalSince(since) >= steadyFor {
                    isCountingDown = true
                    countdownMisses = 0
                    actions.append(.startCountdown)
                    return actions
                }
            } else {
                framedAnchor = center
                framedSince = now
            }
            if !framedAnnounced, !voiceBusy, candidateCount >= 2,
               now.timeIntervalSince(lastSpokenAt) >= minGap {
                let text = AimPhrases.phrase(for: .framed, subject: subject, faceCount: faceCount)
                framedAnnounced = true
                lastPhrase = text
                lastSpokenAt = now
                // The steady clock starts after the sentence, not during it.
                framedSince = now
                actions.append(.say(text, .success))
            }
            return actions
        }

        framedSince = nil
        framedAnchor = nil
        framedAnnounced = false

        guard candidateCount >= 2 || instruction == .notFound else { return [] }
        let text = AimPhrases.phrase(for: instruction, subject: subject, faceCount: faceCount)
        let quiet = now.timeIntervalSince(lastSpokenAt)
        let again = instruction == .notFound ? notFoundRepeat : repeatInterval
        if voiceBusy { return [] }
        if text == lastPhrase, quiet < again { return [] }
        if quiet < minGap { return [] }
        lastPhrase = text
        lastSpokenAt = now
        return [.say(text, instruction == .notFound ? .none : .tick)]
    }

    /// Light smoothing so a box that jitters a few pixels does not flip the
    /// instruction, and a one-frame dropout does not count as lost.
    private mutating func track(_ raw: CGRect?, now: Date) -> CGRect? {
        if let raw {
            lastSeen = now
            if let old = smoothedBox {
                let a: CGFloat = 0.6
                smoothedBox = CGRect(
                    x: old.minX + (raw.minX - old.minX) * a,
                    y: old.minY + (raw.minY - old.minY) * a,
                    width: old.width + (raw.width - old.width) * a,
                    height: old.height + (raw.height - old.height) * a)
            } else {
                smoothedBox = raw
            }
            return smoothedBox
        }
        if let seen = lastSeen, now.timeIntervalSince(seen) <= holdLastBox {
            return smoothedBox
        }
        smoothedBox = nil
        return nil
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
