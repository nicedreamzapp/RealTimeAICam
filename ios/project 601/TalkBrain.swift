import CoreGraphics
import Foundation

// MARK: - Talk to the camera: the pure part
//
// Matt, 2026-10-31: "talk to the camera" like ChatGPT's video mode, but fully
// on the phone. Point it at a car engine, ask, and it tells you what it is and
// walks you through it. Talk is a hybrid of what the app already does:
//   - the 601-object detector keeps running every frame, and its live list
//     (with left / ahead / right) goes into every question, so "what's in
//     front of me" has an instant floor and new things are caught fast;
//   - What's this? and Talk share one engine and one memory: "what's this"
//     spoken in Talk is just a question, and a What's this? answer from the
//     button screen is remembered for a follow-up in Talk;
//   - aim help is part of the conversation, from the existing FrameQualityGate
//     and Help Me Aim steering (no new aim maths here).
//
// Everything in this file is plain logic on strings and boxes, unit tested
// without a camera, a microphone or a model.

/// One thing the detector sees right now. `box` is normalized to the upright
/// frame, origin top-left, the same space as YOLODetection.rect in portrait.
struct TalkSeen: Equatable {
    var name: String
    var box: CGRect

    /// "on your left", "ahead", "on your right": the same thirds the detector
    /// voice uses (LiDARManager.horizontalBucket).
    var whereWords: String {
        switch LiDARManager.horizontalBucket(forNormalizedX: box.midX) {
        case "L": "on the left"
        case "R": "on the right"
        default: "ahead"
        }
    }
}

// MARK: - Scene memory

/// What the detector has seen over the last half minute, shared with live
/// narration later (Matt's "only say what's NEW", 10/30). Updated from the
/// detector on every frame it finishes; read when a question comes in.
struct TalkSceneMemory {
    /// How long something stays remembered after it was last seen.
    static let window: TimeInterval = 30
    /// Something first seen this recently counts as new.
    static let newWindow: TimeInterval = 8

    private(set) var now: [TalkSeen] = []
    private var firstSeen: [String: Date] = [:]
    private var lastSeen: [String: Date] = [:]
    /// The most recent describe answer, used as the scene caption.
    private(set) var caption: String?
    private(set) var captionAt: Date?

    mutating func update(_ seen: [TalkSeen], at time: Date) {
        now = seen
        for s in seen {
            // Back after being gone for the whole window: new again.
            if let last = lastSeen[s.name], time.timeIntervalSince(last) > Self.window {
                firstSeen[s.name] = time
            }
            if firstSeen[s.name] == nil { firstSeen[s.name] = time }
            lastSeen[s.name] = time
        }
        for (name, last) in lastSeen where time.timeIntervalSince(last) > Self.window {
            lastSeen[name] = nil
            firstSeen[name] = nil
        }
    }

    mutating func noteCaption(_ text: String, at time: Date) {
        caption = text
        captionAt = time
    }

    /// Up to `limit` things in view, nearest the middle first, one per name.
    func inView(limit: Int = 6) -> [TalkSeen] {
        let sorted = now.sorted { a, b in
            let da = hypot(a.box.midX - 0.5, a.box.midY - 0.5)
            let db = hypot(b.box.midX - 0.5, b.box.midY - 0.5)
            if abs(da - db) > 0.0001 { return da < db }
            return a.box.width * a.box.height > b.box.width * b.box.height
        }
        var out: [TalkSeen] = []
        for s in sorted where !out.contains(where: { $0.name == s.name }) {
            out.append(s)
            if out.count == limit { break }
        }
        return out
    }

    /// Names first seen within `newWindow` of `time` and still in view.
    func newThings(at time: Date) -> [String] {
        inView(limit: 10).map(\.name).filter { name in
            guard let first = firstSeen[name] else { return false }
            return time.timeIntervalSince(first) <= Self.newWindow
        }
    }

    /// The scene caption if it is recent enough to still be true.
    func freshCaption(at time: Date, maxAge: TimeInterval = 20) -> String? {
        guard let caption, let at = captionAt, time.timeIntervalSince(at) <= maxAge else { return nil }
        return caption
    }
}

// MARK: - Conversation memory

/// The last few exchanges, so "what about that hose?" knows what "that" is.
/// One shared copy: What's this? answers from the button screen land here too.
final class TalkMemory: @unchecked Sendable {
    static let shared = TalkMemory()

    struct Exchange: Equatable {
        var question: String
        var answer: String
        var at: Date
    }

    /// Keep this many exchanges.
    static let keep = 3
    /// Forget an exchange this long after it happened (a new subject by then).
    static let maxAge: TimeInterval = 180
    /// Each remembered answer is cut to this many characters in the prompt.
    static let answerChars = 220

    private let lock = NSLock()
    private var items: [Exchange] = []

    func note(question: String, answer: String, at time: Date = Date()) {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        items.append(Exchange(question: question, answer: a, at: time))
        if items.count > Self.keep { items.removeFirst(items.count - Self.keep) }
    }

    func recent(at time: Date = Date()) -> [Exchange] {
        lock.lock(); defer { lock.unlock() }
        return items.filter { time.timeIntervalSince($0.at) <= Self.maxAge }
    }

    var lastAnswer: String? {
        lock.lock(); defer { lock.unlock() }
        return items.last?.answer
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }
}

// MARK: - What kind of question

enum TalkTurnKind: Equatable {
    /// End Talk ("stop", "goodbye").
    case end
    /// Say the last answer again.
    case repeatLast
    /// A question about the camera view.
    case ask
}

enum TalkRouting {
    /// Words that mean a page, money, medicine or a label: these keep the
    /// existing most-accurate routing (ModelPicker's page budget, the strict
    /// page reader, the money cross-check).
    static let pageWords = [
        "read", "says", "say on", "written", "printed", "text", "words", "letter", "mail", "envelope",
        "bill", "invoice", "receipt", "statement", "due", "owe", "balance", "price", "cost", "how much",
        "dollar", "money", "cash", "note", "coin", "check", "cheque", "medicine", "medication", "pill",
        "tablet", "capsule", "prescription", "dose", "dosage", "label", "expir", "ingredient", "directions",
        "instructions", "warning", "address", "sender", "page", "document", "form", "menu", "sign",
    ]

    /// "What's this" in any of its spoken shapes: the What's this? button,
    /// asked out loud.
    static let whatsThisPhrases = [
        "what's this", "what is this", "whats this", "what is that", "what's that", "whats that",
        "what am i looking at", "what do you see", "what can you see", "describe", "what's in front of me",
        "what is in front of me", "whats in front of me", "what's here", "what is here", "where am i",
        "what's around me", "what is around me", "tell me what you see", "look at this",
    ]

    static let endPhrases = ["stop talking mode", "end talk", "exit talk", "goodbye", "good bye", "bye bye",
                             "stop listening", "that's all", "that is all", "close talk"]
    static let repeatPhrases = ["say that again", "repeat that", "repeat", "what did you say", "come again",
                                "say it again", "one more time"]

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let kept = lowered.unicodeScalars.map { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            || $0 == "'" || $0 == " " ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    static func intent(of question: String) -> TalkTurnKind {
        let q = normalize(question)
        if q == "stop" || q == "stop it" || q == "quit" || q == "exit" { return .end }
        if endPhrases.contains(where: { q.contains($0) }) { return .end }
        if repeatPhrases.contains(where: { q == $0 || q.hasPrefix($0 + " ") || q.hasSuffix(" " + $0) }) {
            return .repeatLast
        }
        return .ask
    }

    static func isWhatsThis(_ question: String) -> Bool {
        let q = normalize(question)
        return whatsThisPhrases.contains { q.contains($0) }
    }

    /// Does the question itself ask about a page, money, medicine or a label?
    static func asksAboutPage(_ question: String) -> Bool {
        let q = " " + normalize(question) + " "
        return pageWords.contains { word in
            // Whole words, except stems ("expir" for expires / expiry / expiration).
            word == "expir" ? q.contains(" expir") : q.contains(" \(word) ") || q.contains(" \(word)s ")
        }
    }

    /// Short state words a screen reader says while the mic opens. When one of
    /// these is all that was heard, it was the phone, not the person.
    static let echoes: Set<String> = ["listening", "thinking", "answering", "talk", "talk mode", "stop",
                                      "stopped", "ok", "okay"]

    static func isEcho(_ transcript: String) -> Bool {
        echoes.contains(normalize(transcript))
    }

    /// The detected thing the question names, if any ("is the cup full" with
    /// a cup in view). Matches whole words, singular or plural.
    static func namedThing(in question: String, among seen: [TalkSeen]) -> TalkSeen? {
        let words = Set(normalize(question).split(separator: " ").map(String.init))
        let q = " " + normalize(question) + " "
        // Bigger boxes first: the main subject, not a far copy of it.
        for s in seen.sorted(by: { $0.box.width * $0.box.height > $1.box.width * $1.box.height }) {
            let name = normalize(SpeakableText.className(s.name))
            guard !name.isEmpty else { continue }
            if name.contains(" ") {
                if q.contains(" \(name) ") || q.contains(" \(name)s ") { return s }
            } else if AimVocabulary.forms(of: name).contains(where: words.contains)
                || words.contains(name + "s") || words.contains(name + "es") {
                return s
            }
        }
        return nil
    }
}

// MARK: - The prompt

enum TalkPrompt {
    /// The instruction for every Talk answer. Same voice as RT Cam's describe
    /// and ask instructions: answer first, short, spoken, honest.
    static let system = """
    You are the eyes of a blind person, talking with them live through their phone camera. They ask about what the camera sees right now. Answer in one to three short spoken sentences, under 35 words in all, and start with the answer itself. Trust the photo first; the list of detected objects and the earlier conversation are only hints, so never mention the detector or its list. When they say it, that or this, they mean the main thing in the photo or the thing you last talked about. Say where things are as left, right, ahead, up or down. If they ask how to do or fix something, say what it is and give only the next one or two steps, then stop. If the photo does not show the answer, say you can't tell and say what you can see. Never say the photo is too dark, blurry or low resolution to answer; describe whatever you can make out. Plain words, no lists, no markdown.
    """

    /// The text that goes with the photo: what the detector sees, what just
    /// appeared, the last few exchanges, then the question.
    static func userText(question: String, seen: [TalkSeen], newThings: [String], caption: String?,
                         history: [TalkMemory.Exchange]) -> String {
        var lines: [String] = []
        if !seen.isEmpty {
            let list = seen.map { "\(SpeakableText.className($0.name)) \($0.whereWords)" }.joined(separator: ", ")
            lines.append("Detector sees (it can be wrong): \(list).")
        }
        if !newThings.isEmpty {
            lines.append("Just appeared: \(newThings.map(SpeakableText.className).joined(separator: ", ")).")
        }
        if let caption, !history.contains(where: { $0.answer == caption }) {
            lines.append("A moment ago the scene was: \(clip(caption, TalkMemory.answerChars))")
        }
        if !history.isEmpty {
            lines.append("Earlier in this conversation:")
            for h in history {
                lines.append("They asked: \(clip(h.question, 120))")
                lines.append("You said: \(clip(h.answer, TalkMemory.answerChars))")
            }
        }
        // "What's this" asked out loud is the What's this? button: ask it the
        // way the describe path does, main thing first.
        if TalkRouting.isWhatsThis(question) {
            lines.append("Question: \(question) Say what the camera is pointed at, the main thing first, then what is around it.")
        } else {
            lines.append("Question: \(question)")
        }
        return lines.joined(separator: "\n")
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > n else { return t }
        return String(t.prefix(n)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The instant line from the detector alone, said first on a phone where
    /// the model takes a while ("I can see a chair on the left and a person
    /// ahead."). Nil when the detector has nothing.
    static func detectorLine(_ seen: [TalkSeen]) -> String? {
        let items = seen.prefix(3).map { "\(AimVocabulary.withArticle(SpeakableText.className($0.name))) \($0.whereWords)" }
        guard !items.isEmpty else { return nil }
        let list = items.count == 1 ? items[0]
            : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        return "I can see \(list)."
    }
}

// MARK: - Speaking while the model is still writing

/// Turns the model's growing text into whole sentences as soon as each one is
/// finished, so the first sentence is spoken while the rest is being written.
struct TalkSentenceStream {
    private(set) var emitted = 0
    /// Characters of the cleaned text already handed out.
    private var consumed = 0

    /// The sentences finished since the last call. `text` is everything the
    /// model has written so far; `final` flushes the unfinished tail.
    mutating func feed(_ text: String, final: Bool = false) -> [String] {
        let clean = Self.cleaned(text)
        guard clean.count > consumed else { return [] }
        let rest = String(clean.dropFirst(consumed))
        var out: [String] = []
        var current = ""
        var used = 0
        var pendingEnd = false
        for ch in rest {
            if pendingEnd {
                if ch == " " || ch == "\n" {
                    let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { out.append(s) }
                    consumed += used
                    current = ""; used = 0
                    pendingEnd = false
                    // The space itself belongs to nobody.
                    consumed += 1
                    continue
                } else if !".!?\"')".contains(ch) {
                    // "3.5" or "e.g": not a sentence end after all.
                    pendingEnd = false
                }
            }
            current.append(ch); used += 1
            if ".!?".contains(ch), current.trimmingCharacters(in: .whitespaces).count > 1 { pendingEnd = true }
        }
        if final {
            let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            consumed += used
        }
        out = out.filter { s in s.contains { $0.isLetter || $0.isNumber } }
        emitted += out.count
        return out
    }

    /// The model's text minus anything that must never be spoken: a thinking
    /// block, markdown marks, a trailing broken character.
    static func cleaned(_ text: String) -> String {
        var t = text
        if let open = t.range(of: "<think>") {
            if let close = t.range(of: "</think>", range: open.upperBound ..< t.endIndex) {
                t.removeSubrange(open.lowerBound ..< close.upperBound)
            } else {
                t = String(t[..<open.lowerBound])
            }
        }
        if let stray = t.range(of: "</think>") { t = String(t[stray.upperBound...]) }
        t = t.replacingOccurrences(of: "\u{FFFD}", with: "")
        t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")
        // Leading whitespace only: trailing space is how a sentence end is seen.
        while let f = t.first, f == " " || f == "\n" || f == "\"" { t.removeFirst() }
        return t
    }
}

// MARK: - Aim help, from the existing gate and steering

enum TalkAim {
    /// FrameQualityGate's numbers turned into one short spoken tip, or nil.
    static func qualityTip(_ hint: String?) -> String? {
        switch hint {
        case "dark": "It's dark here. The light button is at the top of the screen."
        case "washed out by glare": "There's glare. Tilt the phone a little."
        case "blurry": "Hold the phone still for a better look."
        default: nil
        }
    }

    /// A page that runs off an edge of the frame: which way to move.
    static func instruction(forCutOffEdge edge: String?) -> AimInstruction? {
        switch edge {
        case "left": .moveLeft
        case "right": .moveRight
        case "top": .moveUp
        case "bottom": .moveDown
        default: nil
        }
    }

    /// The page tip, in Help Me Aim's words: "Cut off on the left, move the
    /// phone left a little."
    static func pageTip(cutOffEdge edge: String?) -> String? {
        guard let edge, let i = instruction(forCutOffEdge: edge) else { return nil }
        return "Cut off on the \(edge), \(AimPhrases.phrase(for: i, subject: .page)) a little."
    }

    /// The thing the question was about is cut off or far off to one side:
    /// Help Me Aim's steering on the detector's box, loose zone (the person is
    /// not taking a photo, only giving the camera a better look).
    static func subjectTip(for seen: TalkSeen) -> String? {
        let instruction = AimSteering.instruction(for: seen.box, framing: .whole, loose: true)
        switch instruction {
        case .framed, .notFound: return nil
        default:
            let subject = AimSubject.object(AimVocabulary.Match(spokenName: SpeakableText.className(seen.name),
                                                                classNames: [seen.name], classIDs: []))
            let phrase = AimPhrases.phrase(for: instruction, subject: subject)
            return "For a better look at the \(SpeakableText.className(seen.name)), \(phrase)."
        }
    }

    /// At most one tip per answer: a cut-off page beats a named subject, and
    /// either beats a lighting note.
    static func tip(isPage: Bool, cutOffEdge: String?, named: TalkSeen?, qualityHint: String?) -> String? {
        if isPage, let t = pageTip(cutOffEdge: cutOffEdge) { return t }
        if let named, let t = subjectTip(for: named) { return t }
        return qualityTip(qualityHint)
    }
}

// MARK: - Timing

enum TalkTiming {
    /// The end of a question: this long without a new word.
    static let endOfSentence: TimeInterval = 1.2
    /// Wait this long after the app stops talking before the mic opens, so
    /// the tail of its own voice is never heard.
    static let afterSpeaking: TimeInterval = 0.3
    /// A recognition task is restarted after this long with nothing heard
    /// (Apple caps one task at about a minute).
    static let idleRestart: TimeInterval = 45
    /// Say the detector's instant line first when the model is expected to
    /// take longer than this.
    static let slowModel: TimeInterval = 4

    static func questionEnded(heardSomething: Bool, quiet: TimeInterval) -> Bool {
        heardSomething && quiet >= endOfSentence
    }
}

/// Talking over the app: a voice clearly louder than the app's own echo, for
/// long enough that a cough or a bump does not count.
struct TalkBargeIn {
    /// Below this level (dBFS) nothing counts, whatever the echo is doing.
    static let floor: Float = -38
    /// The voice must be this many dB above the echo level.
    static let margin: Float = 10
    /// Loud buffers in a row needed (about a quarter second at 1024 frames).
    static let needed = 6

    private(set) var echo: Float = -60
    private var loud = 0

    /// Feed one buffer's level while the app is speaking. True = barge in.
    mutating func feed(level db: Float) -> Bool {
        if db > max(Self.floor, echo + Self.margin) {
            loud += 1
        } else {
            loud = 0
            // Follow the echo level, quicker up than down.
            echo = db > echo ? echo * 0.7 + db * 0.3 : echo * 0.95 + db * 0.05
        }
        return loud >= Self.needed
    }

    mutating func reset() {
        echo = -60
        loud = 0
    }
}
