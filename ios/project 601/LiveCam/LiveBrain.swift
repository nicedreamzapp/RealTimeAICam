// Live Cam, the pure part: what is said, when, and what is remembered. Plain logic, no camera,
// mic or model, so it is unit tested (LiveBrainTests). Ported 2026-11-04 from Moonstone's Live camera
// (divine-tribe-hq shared/moonstone-ios/App/LiveCamera/LiveBrain.swift), which was first ported from RT Cam's
// Talk mode. Every tuning note below is Matt's, kept as is; only the name (Live Cam, not Moonstone) and the
// blind-first line in the prompts are new.
import CoreGraphics
import Foundation

// MARK: - Speaking while the model is still writing

/// Turns the model's growing text into whole sentences as soon as each is finished.
struct LiveSentenceStream {
    private var consumed = 0

    mutating func feed(_ text: String, final: Bool = false) -> [String] {
        let clean = Self.cleaned(text)
        guard clean.count > consumed else { return [] }
        let rest = String(clean.dropFirst(consumed))
        var out: [String] = []
        var current = ""
        var used = 0
        var pendingEnd = false
        let chars = Array(rest)
        for (i, ch) in chars.enumerated() {
            if pendingEnd {
                if ch == " " || ch == "\n" {
                    // A real end is followed by a capital or a digit: "Raider Day!" sign above" is not.
                    guard let next = chars[(i + 1)...].first(where: { $0 != " " && $0 != "\n" }) else {
                        if final { break } else { return out.filter { $0.contains { $0.isLetter || $0.isNumber } } }
                    }
                    if next.isLowercase { pendingEnd = false; current.append(ch); used += 1; continue }
                    let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { out.append(s) }
                    consumed += used + 1
                    current = ""; used = 0; pendingEnd = false
                    continue
                } else if !".!?\"')".contains(ch) {
                    pendingEnd = false   // "3.5", "e.g": not an end
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
        return out.filter { $0.contains { $0.isLetter || $0.isNumber } }
    }

    static func cleaned(_ text: String) -> String {
        var t = text
        if let open = t.range(of: "<think>") {
            if let close = t.range(of: "</think>", range: open.upperBound ..< t.endIndex) {
                t.removeSubrange(open.lowerBound ..< close.upperBound)
            } else { t = String(t[..<open.lowerBound]) }
        }
        if let stray = t.range(of: "</think>") { t = String(t[stray.upperBound...]) }
        t = t.replacingOccurrences(of: "\u{FFFD}", with: "")
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")
        while let f = t.first, f == " " || f == "\n" || f == "\"" { t.removeFirst() }
        // "No, I can't tell": keep the honest half only.
        if let r = t.range(of: #"^(Yes|No)[,.]? (?=I can'?t tell|I'?m not sure)"#, options: .regularExpression) { t.removeSubrange(r) }
        return t
    }
}

// MARK: - Memory

struct LiveExchange: Equatable { var question: String; var answer: String; var at: Date }

struct LiveMemory {
    /// Only the last two exchanges, and only fresh ones, so an old answer (the "posture" one) can't
    /// leak into a new question (Matt, 10/31).
    static let keep = 2
    static let maxAge: TimeInterval = 90
    /// Everything said this call (answers and comments), so the watch never repeats itself.
    private(set) var said: [String] = []
    private(set) var exchanges: [LiveExchange] = []
    /// The last thing said about the view (asked or not), so it is never repeated.
    private(set) var lastSeen: String?

    mutating func note(question: String, answer: String, at t: Date = Date()) {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        exchanges.append(LiveExchange(question: question, answer: a, at: t))
        said.append(a)
        noteThings([a])   // named in an answer = named (run 3: "Oh, I see metal shelving now" after it had said shelving)
        if exchanges.count > Self.keep { exchanges.removeFirst(exchanges.count - Self.keep) }
        lastSeen = a
    }

    mutating func noteSeen(_ line: String) { lastSeen = line; said.append(line); noteThings([line]) }

    /// 11/2 Matt: "say everything in the room once... if you're walking on the bridge for half an hour it shouldn't
    /// keep saying it sees the bridge, it should wait for a boat". Every word it has named this call; a thing is
    /// mentioned once, then only something new gets a line.
    private(set) var seenThings: Set<String> = []
    mutating func noteThings(_ items: [String]) { for i in items { seenThings.formUnion(Self.stems(i)) } }
    /// "shelves" / "shelving" / "shelf" are one thing (11/2 test: "Oh, I see shelves now" after "metal shelving").
    static func stems(_ s: String) -> Set<String> {
        Set(LiveWords.contentWords(s).map { w in
            for suf in ["ving", "ves", "ing", "es", "s", "f"] where w.count > suf.count + 2 && w.hasSuffix(suf) { return String(w.dropLast(suf.count)) }   // shelf/shelves/shelving -> shel
            return w
        })
    }
    /// The listed things it has never named this call, people and their clothes left out.
    func newThings(_ items: [String]) -> [String] {
        items.filter { item in
            let w = Self.stems(item)
            return !w.isEmpty && w.isDisjoint(with: seenThings) && LiveWords.contentWords(item).isDisjoint(with: LiveWords.personWords)
                && LiveWords.contentWords(item).isDisjoint(with: LiveWords.boringThings)   // test 7: "Oh, I see a floor now"
        }
    }

    /// A different room (Matt 11/09: fresh memory on close or a new room): what was told no longer counts.
    mutating func forgetThings() { seenThings = [] }

    /// Every thing a sentence names was already told (a wall, the table, the same chair, the same person): the
    /// sentence adds nothing. Matt 11/09: "it shouldn't keep saying it sees a table every time".
    func addsNothing(_ sentence: String) -> Bool {
        let words = LiveWords.contentWords(sentence).subtracting(LiveWords.personWords).subtracting(LiveWords.boringThings)
            .subtracting(LiveWords.placeWords)
        let fresh = words.filter { Self.stems($0).isDisjoint(with: seenThings) }
        return !seenThings.isEmpty && fresh.isEmpty
    }

    func recent(at t: Date = Date()) -> [LiveExchange] { exchanges.filter { t.timeIntervalSince($0.at) <= Self.maxAge } }
    var lastAnswer: String? { exchanges.last?.answer }
}

// MARK: - Never the same words twice (Matt 11/6)

/// Matt 11/6: "I don't want it to keep asking if it can help constantly, and not to repeat itself. Repeating itself,
/// it glitches, and should not repeat phrases." Every model sentence is vetted here before it is spoken: a sentence
/// already said this visit is dropped, a sentence that loops (a 4+ word phrase twice inside it) is cut where it starts
/// again, a second help offer is dropped, and an "I see..." right after another "I see..." is reworded.
struct LiveSayGuard {
    private(set) var said: Set<String> = []
    /// The first three words of the last line said (normalized), so no two lines in a row open the same way.
    private(set) var lastOpening: String?
    /// It has offered help once this visit.
    private(set) var helpOffered = false

    static func opening(_ s: String) -> String { LiveWords.normalize(s).split(separator: " ").prefix(3).joined(separator: " ") }

    /// The sentence to say, or nil to say nothing.
    func vet(_ sentence: String, prompted: Bool = false) -> String? {
        var s = Self.cutLoop(sentence).trimmingCharacters(in: .whitespaces)
        let n = LiveWords.normalize(s)
        guard !n.isEmpty else { return nil }
        if helpOffered, LiveWords.isHelpOffer(s) { return nil }
        // Review 11/6: an answer to a question is never blocked for being said before ("Yes." to two questions);
        // only a sentence repeated inside the same answer is. Said-before applies to lines it says unasked, and only
        // to a real sentence (5+ words).
        if turnSaid.contains(n) { return nil }
        if !prompted, n.split(separator: " ").count >= 5, said.contains(n) { return nil }
        if let last = lastOpening, Self.opening(s) == last || (last.hasPrefix("i see") && Self.opening(s).hasPrefix("i see")) { s = Self.reworded(s) }
        let r = LiveWords.normalize(s)
        if turnSaid.contains(r) || (!prompted && r.split(separator: " ").count >= 5 && said.contains(r)) { return nil }
        return s
    }

    /// This answer's sentences so far (a sentence repeated inside one answer is the 2B model looping).
    private(set) var turnSaid: Set<String> = []
    mutating func beginTurn() { turnSaid = [] }

    /// Remember a line that is being said (model sentences and the app's own lines alike).
    mutating func note(_ line: String) {
        let n = LiveWords.normalize(line)
        guard !n.isEmpty else { return }
        said.insert(n)
        turnSaid.insert(n)
        lastOpening = Self.opening(line)
        if LiveWords.isHelpOffer(line) { helpOffered = true }
    }

    /// The new-thing line for now: the one help offer if it hasn't been made, else just the thing, never opening
    /// with "I see" twice in a row.
    /// "I see a dog." or "There's a dog.", never with an offer of help.
    var plainNewThingFormat: String {
        lastOpening?.hasPrefix("i see") == true ? LiveCamWords.newThingThere : LiveCamWords.newThingPlain
    }

    var newThingFormat: String {
        if !helpOffered { return LiveCamWords.newThing }
        return lastOpening?.hasPrefix("i see") == true ? LiveCamWords.newThingThere : LiveCamWords.newThingPlain
    }

    /// "I see a red cup" after "I see a book" becomes "There's a red cup" (the small model opens every line with it).
    static func reworded(_ s: String) -> String {
        guard let r = s.range(of: #"^\s*I see\s+"#, options: [.regularExpression, .caseInsensitive]) else { return s }
        let rest = String(s[r.upperBound...])
        let next = LiveWords.normalize(rest).split(separator: " ").first.map(String.init) ?? ""
        if let r2 = rest.range(of: #"^that\s+"#, options: [.regularExpression, .caseInsensitive]) {
            let t = String(rest[r2.upperBound...]); return t.prefix(1).uppercased() + t.dropFirst()
        }
        return (["a", "an", "one", "the", "some"].contains(next) ? "There's " : "There are ") + rest
    }

    /// The 2B model sometimes loops ("the cup is on the table and the cup is on the table and the cup..."): the
    /// sentence is cut where a phrase of 4+ words starts over, and ends cleanly.
    static func cutLoop(_ s: String) -> String {
        let words = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let norm = words.map { LiveWords.normalize($0) }
        guard words.count >= 8 else { return s }
        var seen: [String: Int] = [:]
        for i in 0 ... words.count - 4 {
            let gram = norm[i ..< i + 4].joined(separator: " ")
            if let j = seen[gram], i >= j + 4 {
                var kept = Array(words[..<i])
                while let last = kept.last, LiveTiming.trailing.contains(LiveWords.normalize(last)) || LiveWords.normalize(last).isEmpty { kept.removeLast() }
                guard !kept.isEmpty else { return s }
                var out = kept.joined(separator: " ")
                while let c = out.last, ",;:-".contains(c) { out.removeLast() }
                if let c = out.last, !".!?".contains(c) { out += "." }
                return out
            }
            if seen[gram] == nil { seen[gram] = i }
        }
        return s
    }
}

/// Lines that take turns: none comes back until all have been used, and never the one just said (Matt 11/6).
struct LiveRotation {
    private(set) var used: [String] = []
    private(set) var last: String?
    mutating func next(from lines: [String], random: Int = Int.random(in: 0 ..< 1000)) -> String? {
        guard !lines.isEmpty else { return nil }
        var fresh = lines.filter { !used.contains($0) }
        if fresh.isEmpty { used.removeAll(); fresh = lines.filter { $0 != last } }
        if fresh.isEmpty { fresh = lines }
        let pick = fresh[random % fresh.count]
        used.append(pick); last = pick
        return pick
    }
}

// MARK: - A goal for the visit (Matt 11/6: "I need to make it the most useful it can be")

/// "I'm changing a tire", "help me fix my sink": Live Cam remembers what they're doing for the visit, gives the next
/// step, and the step after on the next turn. Plain words in, plain words out (the 2B model only gets a short rider on
/// the question, where it follows rules). "Done", "never mind", "new thing" clear it.
enum LiveGoal {
    struct State: Equatable {
        var task: String
        var step = 1
        var lastStep: String?
        /// When it last asked "Ready for the next step?": a bare "yes" / "ok" means next for 10 s after (review 11/6).
        var askedReadyAt: Date?
        var askedReady: Bool {
            get { askedReadyAt != nil }
            set { askedReadyAt = newValue ? Date() : nil }
        }
        func askedRecently(_ now: Date = Date()) -> Bool { askedReadyAt.map { now.timeIntervalSince($0) <= 10 } ?? false }
    }

    private static let leads: [[String]] = [
        ["can", "you", "help", "me", "with"], ["can", "you", "help", "me"], ["help", "me", "with"], ["help", "me"],
        ["walk", "me", "through"], ["show", "me", "how", "to"], ["teach", "me", "how", "to"], ["how", "do", "i"], ["how", "can", "i"],
        ["i", "m", "trying", "to"], ["i", "am", "trying", "to"], ["i", "need", "to"], ["i", "want", "to"], ["i", "have", "to"],
        ["i", "m", "going", "to"], ["i", "m", "gonna"], ["i", "m", "about", "to"], ["we", "re"], ["i", "m"], ["i", "am"], ["im"]]
    /// Words that aren't a task on their own ("I'm gonna keep working", "help me with this").
    private static let vague: Set<String> = ["keep", "working", "work", "go", "going", "stuff", "it", "this", "that", "something",
        "thing", "things", "now", "here", "there", "out", "with", "on", "please", "a", "the", "bit", "little", "see", "look", "done",
        "fine", "good", "okay", "ok", "back", "home", "busy", "tired", "just", "really", "so", "you", "me", "up", "set", "great",
        "well", "alright", "nothing", "much", "not", "fun", "around", "doing", "my", "your", "for", "to", "of", "in", "an", "and"]
    /// "I'm feeling sick", "I'm just sitting here": a state, not a job.
    private static let notDoing: Set<String> = ["feeling", "being", "sitting", "chilling", "hanging", "waiting", "thinking",
        "wondering", "talking", "listening", "kidding", "joking", "leaving", "going", "getting", "looking", "watching", "standing",
        "walking", "driving", "eating", "sleeping", "working", "trying", "coming", "playing", "having", "saying", "asking"]
    /// Verbs that mean a job with steps, after "help me" / "I need to" (not "help me see").
    private static let notTasks: Set<String> = ["see", "look", "find", "read", "know", "understand", "hear", "remember", "think", "decide"]

    /// The task in their words, "your" for "my": "I'm changing a tire" -> "changing a tire". Nil for anything else.
    static func detect(_ q: String) -> String? {
        if LiveWords.isLooksQuestion(q) || clears(q) { return nil }
        // Review 11/6: "I'm holding a can, what is it?" is a question about the can, never a goal.
        let t = " " + LiveWords.normalize(q) + " "
        // ("Can you help me put this shelf together?" still is: a request, not a what/which/who/where question.)
        if [" what ", " which ", " who ", " where ", " whats "].contains(where: { t.contains($0) }) { return nil }
        guard let lead = lead(of: q) else { return nil }
        let w = words(q)
        var rest = Array(w.dropFirst(lead.count))
        if ["i", "m", "im", "am", "re"].contains(lead.last!) || lead == ["im"] {
            // "I'm changing a tire": a doing word right after; "I'm tired" isn't a task.
            if rest.first == "working", rest.count > 2, rest[1] == "on" { rest.removeFirst(2) }
            else { guard let v = rest.first, v.hasSuffix("ing"), v.count > 4, !notDoing.contains(v) else { return nil } }
        }
        if let v = rest.first, notTasks.contains(v) { return nil }
        while let l = rest.last, ["please", "now", "today", "here", "real", "quick"].contains(l) { rest.removeLast() }
        guard rest.contains(where: { !vague.contains($0) && $0.count > 2 }), rest.count <= 10 else { return nil }
        return LiveWords.clip(rest.map { ["my": "your", "me": "you", "myself": "yourself", "i": "you"][$0] ?? $0 }.joined(separator: " "), 60)
    }

    /// While a goal is going, only an explicit new task switches it ("now I need to fix the faucet"); "I'm putting the
    /// spare on" is a step of the tire, not a new goal (review 11/6).
    static func isExplicitNewTask(_ q: String) -> Bool {
        let t = " " + LiveWords.normalize(q) + " "
        return [" new thing ", " new task ", " something else ", " different thing ", " now i need to ", " now i want to ",
                " now help me ", " instead ", " switch to ", " next i want to "].contains { t.contains($0) }
    }

    /// The words with a leading "now", "next", "so", "okay" dropped ("Now I need to fix the faucet", Matt 11/6).
    static func words(_ q: String) -> [String] {
        var w = LiveWords.normalize(q).split(separator: " ").map(String.init)
        while let f = w.first, ["now", "next", "so", "okay", "ok", "alright", "well", "and", "um", "uh", "then"].contains(f), w.count > 1 { w.removeFirst() }
        return w
    }
    static func lead(of q: String) -> [String]? {
        let w = words(q)
        return leads.first(where: { w.count > $0.count && Array(w.prefix($0.count)) == $0 })
    }
    /// A goal asked for in so many words ("I need to...", "help me...", "how do I..."), not "I'm putting the spare on"
    /// (a step of the goal they are on). Mid-goal, this switches to the new goal (Matt 11/6).
    static func asksForTask(_ q: String) -> Bool {
        guard detect(q) != nil, let l = lead(of: q) else { return false }
        return !["i", "m", "im", "am", "re"].contains(l.last!) && l != ["im"]
    }

    /// Inside a goal, a new task replaces it only when it is clearly another job (review 11/6): "new thing" / "something
    /// else" / "instead", or a task asked for after "now"/"next"/"so"/"okay" that shares no words with the goal or its
    /// last step ("Now I need to fix the faucet" during the tire). "How do I loosen the lug nuts?" or "I need to get the
    /// hubcap off" stay the tire: answered as questions about it.
    static func switchesGoal(_ g: State, _ q: String) -> Bool {
        let t = " " + LiveWords.normalize(q) + " "
        if [" new thing ", " new task ", " something else ", " different thing ", " instead ", " switch to "].contains(where: { t.contains($0) }) {
            return true
        }
        // Never a question ("Okay, how do I get the hubcap off?"), and only after "now" / "next" (review 11/6).
        if [" how do i ", " how can i ", " how to ", " what ", " where ", " whats "].contains(where: { t.contains($0) }) { return false }
        guard let task = detect(q), task != g.task else { return false }
        let raw = LiveWords.normalize(q).split(separator: " ").map(String.init)
        guard let first = raw.first, ["now", "next"].contains(first) else { return false }
        let mine = LiveWords.contentWords(g.task).union(LiveWords.contentWords(g.lastStep ?? ""))
        return LiveWords.contentWords(task).isDisjoint(with: mine)
    }

    /// A quick "ok" to "Ready for the next step?" counts: only once it has stopped talking, and not in the second after
    /// a line of its own that had "okay" in it (review 11/6).
    static func quickOkCounts(_ fresh: [String], askedRecently: Bool, speaking: Bool, sinceItSpoke: TimeInterval, lastSaid: String?) -> Bool {
        guard askedRecently, fresh.count == 1, ["ok", "okay"].contains(fresh[0]), !speaking else { return false }
        let saidOkay = (" " + LiveWords.normalize(lastSaid ?? "") + " ").contains(" okay ") || (" " + LiveWords.normalize(lastSaid ?? "") + " ").contains(" ok ")
        return !(saidOkay && sinceItSpoke < 1.0)
    }

    /// A lone "next" or "ok" heard while it is talking or within a second after it stops is the tail of its own voice
    /// ("Say next when you're ready"), never a step (Matt 11/6).
    static func isEchoTail(_ fresh: [String], speaking: Bool, sinceItSpoke: TimeInterval) -> Bool {
        fresh.count == 1 && ["next", "ok", "okay"].contains(fresh[0]) && (speaking || sinceItSpoke < 1.0)
    }

    /// "Done", "never mind", "new thing": the goal is over.
    static func clears(_ q: String) -> Bool {
        let t = LiveWords.normalize(q)
        if isNext(t) { return false }   // "done, what's next" is the next step, not the end
        if ["done", "i m done", "im done", "all done", "we re done", "finished", "i m finished", "all finished", "that s it", "thats it",
            "never mind", "nevermind", "new thing", "something else", "forget it", "forget that", "stop that", "we re good", "i got it now",
            "it s done", "its done", "i did it", "i fixed it", "it works now", "done with that"].contains(t) { return true }
        let s = " " + t + " "
        return [" new thing ", " something else ", " never mind ", " nevermind ", " different thing ", " i m done ", " all done ",
                " forget it ", " i m finished ", " it works now ", " i fixed it "].contains { s.contains($0) }
    }

    private static func isNext(_ t: String) -> Bool {
        let s = " " + t + " "
        return [" next ", " what now ", " then what ", " and then ", " after that ", " what do i do now ", " keep going ", " go on ",
                " continue ", " what s after ", " ok what s ", " okay what s "].contains { s.contains($0) }
    }

    /// The next step, please: "next", "what's next", "okay done with that", or a bare "yes" right after "Ready for the next step?".
    static func wantsNext(_ q: String, askedReady: Bool) -> Bool {
        let t = LiveWords.normalize(q)
        if isNext(t) { return true }
        if ["got it", "got that", "did that", "done that", "ok did it", "okay did it", "that s done", "thats done", "okay done",
            "ok done", "done next", "finished that"].contains(t) { return true }
        return askedReady && ["yes", "yeah", "yep", "sure", "ready", "ok", "okay", "yes please", "i m ready", "im ready", "go ahead", "let s go",
                              "lets go", "uh huh", "yes i m ready"].contains(t)
    }

    /// Rides on the question (the 2B model follows rules there): the task, the step wanted, the last step given.
    static func rider(_ g: State, next: Bool) -> String {
        var r = " They are working on: \(g.task)."
        if let last = g.lastStep { r += " The step you gave last: \(LiveWords.clip(last, 100))" }
        r += next || g.lastStep == nil
            ? " Give only step \(g.step), the very next thing to do, in one or two short sentences, using what you see if it helps. Don't repeat an earlier step."
            : " Answer what they asked with that task in mind, in one or two short sentences."
        return r
    }

    /// Quiet check-ins while there is a goal (never an offer of help, never the same twice in a row: LiveRotation).
    static let checkIns = ["Ready for the next step?", "How's that step going?", "Say next when you're ready.", "Want the next step?",
                           "Still with me on that step?"]
}

// MARK: - Words

/// One line for Live Cam's voice (2026-11-05, Spanish UI). `own`: the app's own words, an English key said in the
/// app language (AppLang). `content`: what the model said or saw, in English, put into Your language. `withContent`:
/// an app line (a format key with one %@) carrying a piece of content (Coach's goal, a thing it saw).
enum LiveLine: Equatable {
    case own(String)
    case content(String)
    case withContent(String, String)

    /// A `withContent` line is translated whole when Your language is the (non-English) app language and its
    /// translator is ready: "Trabajemos en tu tiro" instead of an English goal inside a Spanish sentence.
    /// Otherwise it is the app language's line with the piece as it is.
    static func translatesWhole(appCode: String, yourCode: String) -> Bool {
        appCode != YourLanguageRules.english && yourCode == appCode
    }
}

enum LiveWords {
    // No welcome or opening narration, ever (Matt 11/09, asked many times; 11/6 "it opens silent"): no greeting
    // lines here, no opening look.
    /// Normal mode, after a long quiet: a friend in the room checking in, never a description of the scene or of
    /// them (11/2 Matt: "not something that's just critiquing everything"). Fixed lines, so the small model can't
    /// slip back into "Now I see...".
    /// Matt 11/6: "I don't want it to keep asking if it can help constantly": the lines that offer help are used only
    /// while no help offer has been made this visit (LiveSayGuard.helpOffered); the rest rotate (LiveRotation).
    static let checkIns = ["What are you up to?", "How's it going over there?", "Working on anything I can help with?",
                           "Need a hand with anything?", "What are you working on?", "Anything you want to talk through?"]
    /// An offer of help ("Anything I can help with?", "Need a hand?"), said or written: at most one per visit (Matt 11/6).
    static func isHelpOffer(_ s: String) -> Bool {
        let t = " " + normalize(s) + " "
        return [" help with ", " help you ", " can i help ", " i can help ", " a hand ", " anything i can do ", " talk through ",
                " need help ", " want help ", " help me help "].contains { t.contains($0) }
    }
    static let system = """
    You are Live Cam, talking with someone live through their phone camera. They may be blind or have low vision, so when you say where something is, say left, right, ahead, near or far. You see the photo of what the camera shows right now. Reply like a friend: one or two short spoken sentences, under 25 words, answer first, unless they ask for more. Use the earlier conversation to know what "it", "that" or "this" means. If they ask how to do or fix something, give only the next step or two. If the question has nothing to do with the photo, ignore the photo and just answer it. How-to questions get real steps from what you know even when the thing isn't in view, and you can do math. If the photo does not show the answer, say so. Be kind about people: never criticize or rate anyone's looks, hair, body or clothes, never call anyone bald or messy, and be extra gentle with children. Don't comment on the person, their face or how they look unless they ask about it, and don't narrate the room: you are a friend who can see, not a commentator. Never say "the photo" or "the image": talk as if you are looking through the camera ("I see..."). No lists, no markdown, no emoji.
    """
    /// Front camera: a selfie chat. Talk TO the person in view, warm and honest.
    static let selfieSystem = """
    You are Live Cam, live with the person in front of the front camera, talking to them as "you" like a warm, kind friend with a good eye. You only get here because they asked how they look, so be useful like a good friend who was asked: one honest, specific tip (posture, fit, color, lighting, framing) and how to fix it, said cordially ("try sitting up a little taller"), plus one real thing that already works. Never call anyone bald, messy, tired-looking, loose or wrong; never comment on hair loss, weight, skin or body, and never rate attractiveness. Be specific, not gushing; never say "perfect". One or two short spoken sentences, under 30 words, unless they ask for more. Use the earlier conversation. Never say "the photo" or "the image". No lists, no markdown, no emoji.
    """
    /// A question that isn't about the camera: no picture, just a friend who knows things and admits what it doesn't.
    static let chatSystem = """
    You are Live Cam, talking with someone live. You run entirely on their phone, offline: you are the vision model inside the RealTime AI Cam app, with no internet. When they say "you", they mean you, Live Cam. Only say what you are or where you run when they ask about you; never introduce yourself or mention the iPhone otherwise (11/1 Matt: "it never needs to say that"). The person talking is "you". Greetings and small talk ("how are you", "what's up") get a warm, normal reply like a friend's ("Doing good, how about you?"), never a refusal. Answer what they ask like a friend: one or two short spoken sentences, under 30 words, answer first, unless they ask for more. You can do math and explain how to fix or do things from what you know. If you don't know or aren't sure, say so plainly instead of guessing; you can't look anything up. You know nothing current: for news, sports results, prices, weather or anything about today or this year, say you can't look that up. Use the earlier conversation. Never say "the photo" or "the image". No lists, no markdown, no emoji.
    """

    /// Only questions about what is in view get the photo; anything else is a plain question (Matt 10/31:
    /// "when I ask things that don't have anything to do with what's in the picture it ... just wants to answer
    /// about what's in the picture"). `lastUsedPhoto`: a short follow-up ("what color is it") stays on the camera.
    static func needsPhoto(_ q: String, lastUsedPhoto: Bool) -> Bool {
        let t = " " + normalize(q) + " "
        if isLooksQuestion(q) { return true }
        // 11/2 sim: "I'm gonna keep working" got "You're bent over a counter with a vacuum hose". Small talk and
        // statements about what they're doing get a friend's reply, not a look, unless they point at something.
        if isSmallTalk(t) || !isQuestionOrAsk(t) { return false }
        // Run 3: "how do I take an alternator off a car" got "I don't see a car". How-to is knowledge, unless they point at it.
        let howTo = [" how do i ", " how to ", " how can i ", " how would i ", " how should i ", " what s the best way "]
        if howTo.contains(where: { t.hasPrefix($0) || (" " + t).hasPrefix($0) }),
           ![" this ", " that ", " it ", " these ", " here "].contains(where: { t.contains($0) }) { return false }
        // About Live Cam itself: never the camera.
        let aboutYou = [" what model ", " which model ", " who are you ", " what are you ", " who made you ", " who built you ",
                        " are you online ", " are you offline ", " your name ", " speaking to ", " talking to ",
                        " yourself ", " was that you ", " is that you ", " you hearing ", " hear yourself "]
        if aboutYou.contains(where: { t.contains($0) }) { return false }
        if t.hasPrefix(" is this ") || t.hasPrefix(" is that ") { return true }
        if isAboutThem(q) { return true }   // "what's my express…" went to the chat voice and got "I can't look that up"
        let seeing = [" see ", " seeing ", " look ", " looking ", " looks ", " watch ", " show ", " showing ", " holding ", " hold ",
                      " wearing ", " wear ", " in front ", " color ", " colour ", " read ", " written ", " write on ", " sign ",
                      " label ", " picture ", " photo ", " camera ", " view ", " room ", " behind ", " around me ", " around here ",
                      " how many ", " count ", " where is ", " where s ", " what is this ", " what s this ", " whats this ",
                      " what is that ", " what s that ", " whats that ", " this one ", " these ",
                      " those ", " identify ", " recognize ", " what kind of ", " what brand ", " in my hand ", " on the table ",
                      " on my ", " light ", " describe", " happening ", " going on ", " notice ", " interesting ", " scene ", " surroundings ", " whats up ", " am i ", " is there ", " are there ", " my face ", " my hair ", " my shirt ", " my outfit ", " here ", " screen ", " point ",
                      " my form ", " my swing ", " my shot ", " my stance ", " my grip ", " my technique ", " doing it right ",
                      " doing this right ", " am i doing ", " how did i do ", " how was that ", " how s that ", " hows that "]
        if seeing.contains(where: { t.contains($0) }) { return true }
        // 11/3 Matt: "what forces are on this beam" went out with no photo. "This"/"these" point at something in view.
        if [" this ", " these ", " those "].contains(where: { t.contains($0) }),
           ![" this year ", " this week ", " this month ", " this weekend ", " this morning ", " this time "].contains(where: { t.contains($0) }) { return true }
        // 11/1 call log: "what about the sunglasses and posture", "what about this handsome fella" went out with no photo,
        // so the model could only reword its last answer. A follow-up about a thing or a person keeps the camera.
        let followUp = [" what about ", " how about ", " and the ", " he ", " she ", " her ", " him ", " his ", " fella ", " guy ",
                        " girl ", " man ", " woman ", " kid ", " baby ", " dog ", " cat ", " sunglasses ", " glasses ", " hat ",
                        " posture ", " outfit ", " now "]
        if lastUsedPhoto, followUp.contains(where: { t.contains($0) }) { return true }
        // "what about that one", "is it ripe": a follow-up to something it was just looking at.
        let pointing = [" it ", " that ", " this ", " they ", " them ", " one "]
        return lastUsedPhoto && t.split(separator: " ").count <= 5 && pointing.contains { t.contains($0) }
    }

    /// A yes-or-no question (Matt 10/31): the answer starts with Yes, No, I'm not sure or I can't tell.
    static func isYesNo(_ q: String) -> Bool {
        guard let first = normalize(q).split(separator: " ").first else { return false }
        return ["is", "are", "am", "do", "does", "did", "can", "could", "will", "would", "should", "has", "have", "was", "were", "isn",
                "aren", "don", "doesn", "didn", "won", "shall", "may"].contains(String(first))
    }

    static let yesNoRule = "It's a yes-or-no question: your first word must be \"Yes\" or \"No\", then one short reason. Talk to them as \"you\"."
    /// With the photo: "I can't tell" is allowed, but only on its own (the 2B model splices "No, I can't tell" otherwise).
    static let yesNoPhotoRule = "It's a yes-or-no question: your first word must be \"Yes\" or \"No\". Only if the photo really doesn't show it, start with \"I can't tell\" instead. Then one short reason. Never combine two openers. Talk to them as \"you\"."

    static func isAboutThem(_ q: String) -> Bool {
        let t = " " + normalize(q) + " "
        return t.contains(" am i ") || t.contains(" my ") || t.contains(" do i look ") || t.contains(" i m ")
    }

    /// Small print, counting, money, far or small things: the 768 px photo; everything else 512 px (about half the image tokens).
    static func needsDetail(_ q: String) -> Bool {
        let t = " " + normalize(q) + " "
        return [" read", " say on ", " says ", " sign", " label", " text", " written", " word", " how many ", " count", " small",
                " tiny", " far ", " distance", " number", " price", " brand", " logo", " ingredient", " serial", " model number",
                // 11/4: money went out at 512 px and a $100's corner numerals read as four $100s.
                " money", " cash", " bill", " dollar", " coin", " total", " how much "].contains { t.contains($0) }
    }

    static func chatQuestion(_ q: String, history: [LiveExchange]) -> String {
        var lines: [String] = []
        if !history.isEmpty {
            lines.append("Earlier:")
            for h in history {
                lines.append("They asked: \(clip(h.question, 120))")   // questions only: it copied its own answers (11/1)
            }
        }
        lines.append("They say now: \(q) Answer only this, directly, from what you know; math and how-to steps you answer yourself, never with \"I can't look that up\". Don't repeat earlier answers." + (isYesNo(q) ? " " + yesNoRule : ""))
        return lines.joined(separator: "\n")
    }

    static let photoIfHelps = "A camera view is attached, but this question is not about it: ignore the view and answer from what you know."

    static let describeNow = "In one short sentence, tell me what you see right now, the main thing first."

    /// The one line Live Cam says on open (Matt 11/09: "it should say what it sees in the screen from the get go,
    /// just a general read of the room"). No greeting, no question, no offer, never the person.
    static let openingRead = "In one short sentence, say what kind of place this is and the main things in it, like \"A kitchen with a table, two chairs and a window.\" No greeting, no question, no offer to help. Never mention the person, their face or clothes."

    /// A thing that just came into view, in one short line (Matt 11/09: "oh, now I see a dog").
    static func newThingAsk(_ thing: String) -> String {
        "In one short sentence that starts with \"Now I see\", say where the \(thing) is in view. Never mention the person, their face or clothes. No question."
    }

    /// Words never allowed in the opening read: a greeting, a warning, an offer, a name.
    static let openingBanned = [" welcome ", " hey ", " hello ", " hi there ", " experimental ", " help ", " how s it going ",
                                " how are you ", " live cam ", " anything i can "]
    static func isOpeningReadable(_ sentence: String) -> Bool {
        let t = " " + normalize(sentence) + " "
        return !sentence.contains("?") && !openingBanned.contains { t.contains($0) }
    }

    /// "What do you see" and nothing more specific: the question a filter for already-told things suits. "What is
    /// this", "where am I", "describe the label" are real questions and always get a full answer (review 11/09).
    static func isSeeAgain(_ q: String) -> Bool {
        let t = " " + normalize(q) + " "
        return [" what do you see ", " what can you see ", " what are you seeing ", " what you see ", " what else do you see ",
                " what do you see now ", " see anything "].contains { t.contains($0) }
    }

    /// "Describe everything again", "the whole room": the full description, not just what's new (Matt 11/09).
    static func wantsEverything(_ q: String) -> Bool {
        let t = " " + normalize(q) + " "
        return [" everything ", " whole room ", " all again ", " describe it all ", " describe all ", " full description ",
                " the whole thing ", " start over "].contains { t.contains($0) }
    }

    /// Words about where things are, not things: never what makes a sentence new.
    static let placeWords: Set<String> = ["left", "right", "front", "behind", "next", "near", "middle", "center", "top", "bottom",
        "side", "back", "there", "here", "still", "same", "also", "some", "few", "two", "three", "several", "large", "small",
        "big", "little", "white", "black", "brown", "wooden", "wood", "gray", "grey", "blue", "red", "green", "yellow", "sitting",
        "standing", "placed", "visible", "view", "looks", "appears", "seems", "inside", "outside", "corner", "above", "below"]

    /// The quiet look while the view changes: a bare list the code compares with what was already named.
    static let inventory = "List the main things in view as short names separated by commas, at most 8. Things only, never the person or their clothes. No sentence."
    static let personWords: Set<String> = ["man", "woman", "person", "people", "guy", "you", "your", "face", "hair", "shirt",
        "hoodie", "jacket", "hat", "glasses", "sunglasses", "beard", "hand", "hands", "arm", "arms", "head", "boy", "girl",
        "child", "kid", "someone", "he", "she", "him", "her", "his", "clothes", "clothing", "smile", "expression",
        "sweatshirt", "sweater", "pants", "jeans", "shoes", "boots", "cap", "sleeve", "gloves", "coat", "vest", "body", "fingers"]
    /// "boxes, a shelf, the forklift" → ["boxes", "shelf", "forklift"]
    static func items(_ list: String) -> [String] {
        list.replacingOccurrences(of: " and ", with: ",").split(whereSeparator: { ",;\n.".contains($0) })
            .map { normalize(String($0)).replacingOccurrences(of: #"^(a|an|the|some|two|three|several|many)\s+"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty && $0.split(separator: " ").count <= 4 }
    }
    /// The double-check (11/2): yes or no only, and "no" when unsure.
    static func confirmAsk(_ thing: String) -> String {
        "Answer with one word, Yes or No. Is there clearly a \(thing) in this photo? If you are not sure, answer No."
    }
    /// "I don't see a computer": nothing to double-check (test 5 took back a thing it had said wasn't there).
    static func saysNotThere(_ s: String) -> Bool {
        let t = " " + normalize(s) + " "
        return [" don t see ", " dont see ", " can t see ", " cant see ", " no ", " not ", " isn t ", " there s nothing ", " can t tell "].contains { t.contains($0) }
    }
    /// Always there, never news.
    static let boringThings: Set<String> = ["floor", "wall", "walls", "ceiling", "light", "lights", "lighting", "beam", "beams", "room",
        "space", "background", "air", "ground", "sky", "window", "door", "corner"]
    /// The phone itself: never a thing to double-check (test 5: "camera, lens").
    static let selfWords: Set<String> = ["camera", "lens", "phone", "photo", "image", "picture", "view", "frame", "screen of the phone"]
    static func extractAsk(_ answer: String) -> String {
        "List the physical objects named in this sentence as short names separated by commas, nothing else. Sentence: \(answer)"
    }
    /// "I see a boat. Anything I can help with?" for one or two new things. Matt 11/6: never "Oh", and it
    /// engages instead of just naming things.
    static func newThingLine(_ things: [String]) -> String {
        "I see " + newThings(things) + ". Anything I can help with?"
    }
    /// "a boat", "an umbrella and boxes": the English things for newThingLine (and its app-language format).
    static func newThings(_ things: [String]) -> String {
        things.prefix(2).map { t in t.hasSuffix("s") || t.hasSuffix("ing") ? t : ("aeiou".contains(t.first ?? "x") ? "an " : "a ") + t }
            .joined(separator: " and ")
    }

    /// The unprompted look: one new line, or exactly NOTHING NEW.
    static func proactive(lastSeen: String?, said: [String] = []) -> String {
        // 11/1: with what it had already said in the prompt, the 2B model kept answering "Now I see a black pickup
        // truck" while the camera moved on, so every look was dropped as a repeat. It now describes only this frame;
        // the code compares with what was said (overlapsSaid/isRepeat) and stays quiet on a repeat.
        guard let lastSeen, !lastSeen.isEmpty else { return describeNow }
        return "In one short sentence that starts with \"Now I see\", say the main thing in view right now. No comparisons or analogies."
    }


    /// Selfie questions about how they look: honest critique, change first, then one real positive.
    static let critique = "Talk to them as \"you\". In two short sentences: first something real you like about how they look, then one honest, specific tip they asked for (posture, fit, color, lighting) and how to fix it, said cordially. No gushing."

    /// Only an explicit ask about their OWN appearance gets the critique. "Does it look like she's
    /// crying" is a question about the scene and gets a straight answer (Matt's first try, 10/31).
    static func isLooksQuestion(_ q: String) -> Bool {
        let t = " " + normalize(q) + " "
        if t.contains(" look like ") || t.contains(" looks like ") { return false }
        let asks = [" how do i look", " how does my ", " how s my ", " hows my ", " how is my ", " rate my ",
                    " do i look ", " what do you think of my ", " what do you think of this outfit",
                    " does this outfit", " does my outfit", " is my outfit", " should i wear", " how are my ",
                    " critique my ", " roast my ", " is my hair", " is my smile", " does my hair", " my outfit ", " how i look", " critique me", " my posture",
                    " give me feedback", " rate me ", " roast me ", " judge me ", " what should i change", " what would you change", " how can i look"]
        return asks.contains { t.contains($0) }
    }

    /// Back camera, asked about themselves (11/1 phone test: "what's my expression" pointed at the dog answered as the dog).
    static let backCameraSelf = " They are behind the phone pointing the back camera away from themselves: describe only what is in view, and if they are not in view, answer with: I can't see you from this side. Never talk as if you were the thing in view."

    /// Asked about Live Cam itself (what model, who made it, online or not).
    /// Below these it is probably guessing (the chosen words' probabilities; 11/2, tuned from the limits test).
    static let unsureMean = 0.8   // run 2: wrong answers 0.70/0.74, right ones 0.77+
    static let unsureLowest = 0.0    // the least sure word didn't separate right from wrong (0.23 on a right answer)

    /// "What did I ask first", "what did you say before", "remember when": reaching back past what it keeps.
    static func reachesBack(_ q: String) -> Bool {
        let t = " " + normalize(q) + " "
        return [" ask first ", " asked first ", " first thing ", " earlier ", " before that ", " a while ago ", " remember when ",
                " do you remember ", " what did i ask ", " what did i say ", " what did you say before ", " last time "].contains { t.contains($0) }
    }

    /// Exact makes, part numbers, news and prices: a 2B offline model guesses these.
    static func pastItsLeague(_ q: String) -> Bool {
        let t = " " + normalize(q) + " "
        return [" brand ", " make and model ", " what model ", " which model ", " what year ", " part number ", " serial ",
                " exact ", " news ", " price ", " cost ", " weather ", " stock ", " score ", " today ", " latest ",
                " square root "].contains { t.contains($0) }
    }

    static func isAboutLiveCam(_ q: String) -> Bool {
        let t = " " + normalize(q) + " "
        return [" what model ", " which model ", " who are you ", " what are you ", " who made you ", " who built you ",
                " are you online ", " are you offline ", " your name ", " speaking to ", " talking to ", " where do you run ",
                " are you on my phone ", " what is live cam ", " what s live cam "].contains { t.contains($0) }
    }

    /// A short pointing follow-up ("what about that one", "and this?") that needs the previous question to make sense.
    static func isShortFollowUp(_ q: String) -> Bool {
        let t = " " + normalize(q) + " "
        return t.split(separator: " ").count <= 5 && [" it ", " that ", " this ", " they ", " them ", " one ", " those ", " these "].contains { t.contains($0) }
    }

    /// What it says, cleaned (11/1 phone test): no unasked "I run on your iPhone, offline", never "the photo".
    static func spoken(_ s: String, aboutMe: Bool) -> String? {
        let l = s.lowercased()
        if !aboutMe, ["on your iphone", "on your phone", "offline", "i'm live cam", "i am live cam", "lfm", "liquid ai"].contains(where: { l.contains($0) }) { return nil }
        var out = s
        // Matt 11/6: never "Oh, I see a map". It just says "I see a map".
        if let r = out.range(of: #"^\s*(Oh wow|Ooh|Oh|Ah|Wow)[,!.]?\s+"#, options: [.regularExpression, .caseInsensitive]) {
            out.removeSubrange(r)
            if let f = out.first { out = f.uppercased() + out.dropFirst() }
        }
        for (a, b) in [(" in the photo", ""), (" in the image", ""), (" in this photo", ""), (" in this image", ""),
                       ("the photo", "the view"), ("the image", "the view"), ("The photo", "The view"), ("The image", "The view")] {
            out = out.replacingOccurrences(of: a, with: b)
        }
        return out.trimmingCharacters(in: .whitespaces).isEmpty ? nil : out
    }

    /// "What do you see now" and friends: a fresh look, judged on this photo alone.
    static func isDescribeNow(_ q: String) -> Bool {
        let t = " " + normalize(q) + " "
        return [" what do you see ", " what can you see ", " what you see ", " what are you seeing ", " what am i looking at ",
                " in front ", " describe ", " look now ", " what s this ", " whats this ", " what is this ", " what s that ",
                " whats that ", " what is that ", " around me ", " where am i "].contains { t.contains($0) }
    }

    static func question(_ q: String, history: [LiveExchange], selfieCritique: Bool = false) -> String {
        var lines: [String] = []
        // 11/1 Matt: "it keeps repeating itself". With its last description in the prompt, the small model copied it
        // word for word for every "what do you see now". A describe question gets the photo and nothing it said before.
        let history = isDescribeNow(q) ? [] : history
        if !history.isEmpty {
            lines.append("Earlier:")
            // Questions only: with "You said: ..." in the prompt the small model repeated its last description even
            // with a new photo (11/1 call log: three "what do you see now" in a row, three identical answers).
            for h in history { lines.append("They asked: \(clip(h.question, 120))") }
            lines.append("Describe only what is in this new photo.")
        }
        lines.append(selfieCritique ? "The person in the photo asks you: \(q) \(critique)"
                                    : "They say now: \(q) Answer only this, directly, from what you see; don't repeat earlier answers. Never say photo or image." + (isYesNo(q) ? " " + yesNoPhotoRule : "")
                                      + (isAboutThem(q) ? " The person in the photo is the one talking to you. Call them \"you\" everywhere." : ""))
        return lines.joined(separator: "\n")
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }

    static func isNothingNew(_ s: String) -> Bool {
        let t = s.uppercased()
        return t.contains("NOTHING NEW") || t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Tiny acknowledgements for a slow answer, never the same one twice in a row.
    static let acks = ["Let me look.", "Okay.", "Hmm, one sec.", "Sure, looking.", "One moment.", "Let me see."]

    static func ack(after last: String?, random: Int = Int.random(in: 0 ..< 1000)) -> String {
        let choices = acks.filter { $0 != last }
        return choices[random % choices.count]
    }

    static func normalize(_ s: String) -> String {
        let kept = s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Already said, near enough word for word.
    static let stopWords: Set<String> = ["a", "an", "the", "i", "see", "now", "is", "are", "and", "with", "of", "in", "on",
        "to", "it", "its", "it's", "there", "this", "that", "some", "you", "your", "looks", "like", "at", "by", "for", "as",
        "be", "has", "have", "just", "still", "also", "new", "which", "one", "two", "front", "background", "foreground"]

    static func contentWords(_ s: String) -> Set<String> {
        Set(normalize(s).split(separator: " ").map(String.init).filter { $0.count > 2 && !stopWords.contains($0) })
    }

    /// Says nothing new compared with anything already said this session (same things, same analogies).
    static func overlapsSaid(_ line: String, said: [String]) -> Bool {
        let a = contentWords(line)
        guard !a.isEmpty else { return true }
        for s in said {
            let b = contentWords(s)
            guard !b.isEmpty else { continue }
            if Double(a.intersection(b).count) / Double(a.count) >= 0.5 { return true }
        }
        return false
    }

    static func isRepeat(_ line: String, of earlier: String?) -> Bool {
        guard let earlier else { return false }
        let a = Set(normalize(line).split(separator: " ")), b = Set(normalize(earlier).split(separator: " "))
        guard !a.isEmpty, !b.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count)) >= 0.6
    }

    enum Turn: Equatable { case end, repeatLast, stopSaying, hush, mode(LiveMode), light(Bool?), ask }

    /// "Turn on the flashlight", "lights off", "flashlight": the light, handled on the phone with no model call
    /// (Matt 11/6). true on, false off, nil switch it. A question about a light ("is the light on") is not one.
    static func lightCommand(_ q: String) -> Bool?? {
        let t = normalize(q)
        let s = " " + t + " "
        let things = [" light ", " lights ", " flashlight ", " torch ", " flash light "]
        guard things.contains(where: { s.contains($0) }) else { return nil }
        let words = t.split(separator: " ").map(String.init)
        guard words.count <= 8, let first = words.first else { return nil }
        if ["is", "are", "what", "where", "does", "do", "why", "how", "which", "was", "did"].contains(first) { return nil }
        if s.contains(" see ") || s.contains(" look") || s.contains(" color ") || s.contains(" read ") { return nil }
        let on = [" turn on ", " switch on ", " light on ", " lights on ", " flashlight on ", " torch on ", " on the light",
                  " on the flashlight", " on the torch", " on my flashlight", " on the lights", " light up ", " need light ",
                  " need a light ", " need some light ", " more light "].contains { s.contains($0) }
            || (s.contains(" turn ") && t.hasSuffix(" on"))
        let off = [" turn off ", " switch off ", " light off ", " lights off ", " flashlight off ", " torch off ", " off the light",
                   " off the flashlight", " off the torch", " kill the light", " no light "].contains { s.contains($0) }
            || (s.contains(" turn ") && t.hasSuffix(" off"))
        if on != off { return .some(on) }
        if ["flashlight", "the flashlight", "light", "toggle the light", "toggle the flashlight", "flashlight please", "torch"].contains(t) { return .some(nil) }
        return nil
    }

    /// "Funny mode", "be funny", "analyze this", "coach me", "back to normal" (Matt 11/1: four modes, switched by voice).
    static func modeSwitch(_ t: String) -> LiveMode? {
        let s = " " + t + " "
        let asks: [(LiveMode, [String])] = [
            // " fun mode ", " trainer mode ", " training mode ": Spanish "modo divertido / modo entrenador" put into English.
            (.funny, [" funny mode ", " be funny ", " make me laugh ", " comedy mode ", " joke mode ", " fun mode "]),
            (.analyze, [" analyze mode ", " analysis mode ", " analyze this ", " analyze it ", " detail mode ", " be detailed ", " analyzing mode ", " analyze "]),
            (.coach, [" coach mode ", " coach me ", " coaching mode ", " trainer mode ", " training mode "]),
            (.normal, [" normal mode ", " back to normal ", " regular mode ", " stop being funny ", " stop coaching ", " default mode "]),
        ]
        for (m, ps) in asks where ps.contains(where: { s.contains($0) }) { return m }
        return nil
    }

    static let modePhrases = [" funny mode ", " be funny ", " analyze mode ", " analysis mode ", " analyze this ", " analyze it ",
                              " analyze ", " detail mode ", " be detailed ", " analyzing mode ", " coach mode ", " coaching mode ", " coach me ",
                              " fun mode ", " trainer mode ", " training mode "]

    /// What they said after the mode words, when the mode words open the sentence: "coach me on my jump shot" ->
    /// "on my jump shot", "can you analyze the forces on this shelf" -> "the forces on this shelf". Nil if nothing real follows.
    static func modeRest(_ q: String) -> String? {
        let s = " " + normalize(q) + " "
        guard let r = modePhrases.compactMap({ s.range(of: $0) })
            .min(by: { $0.lowerBound != $1.lowerBound ? $0.lowerBound < $1.lowerBound : $0.upperBound > $1.upperBound }) else { return nil }
        guard s[s.startIndex ..< r.lowerBound].split(separator: " ").count <= 3 else { return nil }   // "okay can you coach me"
        let rest = s[r.upperBound...].split(separator: " ").map(String.init)
        let filler: Set<String> = ["on", "with", "at", "for", "in", "about", "through", "please", "mode", "now", "me", "and", "so", "this", "it", "that", "on"]
        let trimmed = Array(rest.drop(while: { filler.contains($0) }))
        return trimmed.isEmpty ? nil : trimmed.joined(separator: " ")
    }

    /// The thing to coach, in "your" words: "my jump shot" -> "your jump shot", "i want to get better at chess" -> "chess".
    static func coachGoal(_ said: String) -> String? {
        var w = normalize(said).split(separator: " ").map(String.init)
        let lead: [[String]] = [["i", "want", "to", "get", "better", "at"], ["i", "want", "to", "work", "on"], ["help", "me", "with"],
                                ["i", "want", "coaching", "on"], ["i", "want", "to"], ["i", "want"], ["i", "d", "like", "to"],
                                ["coach", "me", "on"], ["coach", "me"], ["coaching", "on"], ["on"], ["with"], ["at"], ["um"], ["uh"]]
        var changed = true
        while changed {
            changed = false
            for l in lead where w.count > l.count && Array(w.prefix(l.count)) == l { w.removeFirst(l.count); changed = true; break }
        }
        let goal = w.map { ["my": "your", "me": "you", "i": "you", "im": "you're", "myself": "yourself"][$0] ?? $0 }.joined(separator: " ")
        return goal.isEmpty || ["please", "anything", "nothing", "stuff"].contains(goal) ? nil : clip(goal, 60)
    }

    /// "Analyze this", "describe everything": a request for the full close look, not a question to dig into.
    static func isLookCloser(_ q: String) -> Bool {
        let t = normalize(q)
        return isDescribeNow(q) || ["analyze this", "analyze it", "analyze", "analyze that", "look closer", "take a closer look",
                                    "describe everything", "what all do you see", "be detailed"].contains(t)
    }

    // MARK: Is this a real question?

    enum Heard: Equatable { case answer, ignore(String), sayAgain }

    /// Short things that are clearly meant for it even as one or two words.
    static let commands = ["stop", "bye", "goodbye", "repeat", "say that again", "what's this", "whats this", "what is this",
                           "what's that", "whats that", "what is that", "hello", "hey", "hi", "thanks", "thank you",
                           "describe", "what do you see", "end call", "hang up", "go on", "continue", "and",
                           "critique me", "rate me", "roast me", "judge me", "how i look", "my posture", "wait", "shh", "shush", "quiet", "hang on", "never mind", "nevermind",
                           "next", "next step", "what's next", "whats next", "then what", "done", "all done", "new thing"]   // goals (11/6)

    /// Decide whether a finished transcript is a real utterance worth answering. `confidence` is the
    /// recognizer's average word confidence (nil when it gave none); `lastSaid` is Live Cam's own
    /// last sentence, so its own voice picked up by the mic is never treated as a question.
    static func judge(_ text: String, confidence: Double?, isFinal: Bool, lastSaid: String?, sinceItSpoke: TimeInterval = 0) -> Heard {
        let t = normalize(text)
        let words = t.split(separator: " ").count
        if t.isEmpty { return .ignore("empty") }
        if isEcho(text) { return .ignore("screen-reader echo") }
        // Its own voice only reaches the recognizer through a barge-in replay: near word for word, 4+ words.
        // A natural follow-up ("is the man wearing a blue shirt" after "a man in a blue shirt") must get through.
        if let lastSaid, words >= 4, Double(contentWords(t).intersection(contentWords(lastSaid)).count)
            / Double(max(1, contentWords(t).count)) >= 0.8 { return .ignore("its own voice") }
        let command = commands.contains(t) || turn(text) != .ask
        if words < 3, !command { return .ignore("fragment (\(words) word\(words == 1 ? "" : "s"))") }
        let asks = [" what ", " who ", " where ", " when ", " why ", " how ", " which ", " is ", " are ", " do ", " does ", " can ",
                    " tell ", " describe ", " see "].contains { (" " + t + " ").contains($0) }
        if let c = confidence, isFinal, c < 0.2, !asks {
            // Long enough to be meant for it, but too unsure to answer: ask once, otherwise stay quiet.
            return words >= 4 ? .sayAgain : .ignore(String(format: "low confidence %.2f", c))
        }
        // 11/2 Matt, room chatter ("just trying to find a happy balance"): right after it spoke, anything is a reply;
        // later it answers only what is meant for it (its name, "you", a question or a command) and lets side talk go by.
        if command || sinceItSpoke <= replyWindow || isForMe(t) { return .answer }
        return .ignore("side talk")
    }

    /// "Not much, just working on my car", "cool thanks", "I'm gonna keep working": talk, not a request to look.
    static func isSmallTalk(_ t: String) -> Bool {
        let s = " " + t + " "
        let pointsAtSomething = [" see ", " look", " this ", " that ", " these ", " those ", " what ", " which ", " how ",
                                 " where ", " who ", " color ", " read ", " holding ", " in my hand "]
        if pointsAtSomething.contains(where: { s.contains($0) }) { return false }
        let openers = ["i m ", "im ", "i am ", "i ll ", "ill ", "i will ", "i was ", "i got ", "i have ", "i ve ", "i just ",
                       "not much", "nothing", "just ", "cool", "thanks", "thank you", "ok ", "okay", "yeah", "yep", "nope",
                       "sounds ", "good", "great", "alright", "all right", "gonna ", "going to ", "doing ", "pretty good", "fine"]
        return openers.contains { (t + " ").hasPrefix($0) }
    }

    /// A question or a request to look. Anything else is a statement, and a statement never makes it look and
    /// describe (11/2 test: "the phone is loading, camera opened" got "You are the man in the white hard hat...").
    static func isQuestionOrAsk(_ t: String) -> Bool {
        let s = " " + t + " "
        if isForMe(t) && !s.contains(" you ") && !s.contains(" your ") && !s.contains(" live cam ") { return true }   // starts like a question
        return [" what ", " which ", " who ", " where ", " how ", " why ", " is this ", " is that ", " is it ", " are these ",
                " see ", " look ", " check ", " tell me ", " show me ", " describe ", " read ", " identify ", " can you ",
                " could you ", " do you ", " analyze ", " explain ", " coach ", " watch me "].contains { s.contains($0) }
    }

    /// Seconds after it stops talking during which whatever is said counts as a reply.
    static let replyWindow: TimeInterval = 20

    /// Said to Live Cam, not to someone else in the room: its name, "you", a question or a request.
    static func isForMe(_ t: String) -> Bool {
        let s = " " + t + " "
        if [" live cam ", " you ", " your ", " you re ", " youre ", " u "].contains(where: { s.contains($0) }) { return true }
        let starts = ["what", "who", "where", "when", "why", "how", "which", "is", "are", "do", "does", "can", "could", "would",
                      "should", "will", "tell", "describe", "show", "explain", "help", "look", "check", "remind", "give", "read"]
        guard let first = t.split(separator: " ").first.map(String.init) else { return false }
        return starts.contains(first)
    }

    static func turn(_ q: String) -> Turn {
        let t = normalize(q)
        if let l = lightCommand(q) { return .light(l) }
        if ["stop", "end call", "end the call", "hang up", "goodbye", "good bye", "bye", "bye bye"].contains(t)
            || t.hasPrefix("goodbye ") || t.hasSuffix(" goodbye") || t.contains("end the call") || t.contains("hang up") { return .end }
        if ["repeat", "repeat that", "say that again", "what did you say", "come again", "say it again"].contains(t)
            || [" repeat that ", " say that again ", " repeat yourself ", " repeat it ", " come again ", " say it again ",
                " what did you just say ", " repeat what you said ", " repeat the last "].contains(where: { (" " + t + " ").contains($0) })
            && t.split(separator: " ").count <= 8 { return .repeatLast }   // review 11/6: "can you repeat that"
        // 11/3 Matt: "coach me on my jump shot" / "analyze the forces on this" switch the mode AND keep the rest.
        if let m = modeSwitch(t), t.split(separator: " ").count <= 6 || modeRest(q) != nil { return .mode(m) }
        // 11/1 phone test: "Hold on, stop" got a description of the room. These mean be quiet.
        if ["hold on", "hold on stop", "wait", "wait wait", "never mind", "nevermind", "wait never mind", "stop talking",
            "shh", "shush", "quiet", "be quiet", "hang on", "one sec", "one second", "ok stop", "okay stop"].contains(t) { return .hush }
        // 11/1: "you don't need to say that" got the same line again, twice. Feedback about what it said is not a question.
        if [" don t need to say", " dont need to say", " stop saying", " don t say that", " dont say that", " quit saying",
            " you already said", " stop telling me", " no need to say"].contains(where: { (" " + t).contains($0) }) { return .stopSaying }
        return .ask
    }

    /// Short words a screen reader says while the mic opens; never a question.
    static func isEcho(_ s: String) -> Bool { ["listening", "thinking", "speaking", "ok", "okay"].contains(normalize(s)) }
}

// MARK: - Turn taking and the light watch

enum LiveTiming {
    static let endOfSpeech: TimeInterval = 1.0
    static let afterSpeaking: TimeInterval = 0.25
    static let idleRestart: TimeInterval = 45
    /// Say an acknowledgement first when the answer is expected to take longer than this.
    static let ackAfter: TimeInterval = 1.6
    /// The mic itself has been quiet this long (and the words stopped changing): the question is over,
    /// without waiting the full second for the recognizer (Fable 10/31: ~0.5 s of the ~2 s wait).
    static let audioQuiet: TimeInterval = 0.85   // 11/1 phone test: 0.6 split "Hello, how are you doing" at the comma
    static let wordsSettled: TimeInterval = 0.35
    /// Matt 11/6 "it stalls": the orb turns to "looking" this soon after the voice stops (words heard and settled),
    /// before the full end-of-question wait (audioQuietComplete / audioQuiet / endOfSpeech) is over. If they keep
    /// talking it turns back, silently.
    static let showLookingAfter: TimeInterval = 0.4
    static func soundsDone(wordsQuiet: TimeInterval, micQuiet: TimeInterval) -> Bool {
        (micQuiet >= showLookingAfter && wordsQuiet >= wordsSettled) || wordsQuiet >= showLookingAfter + wordsSettled
    }
    /// While it talks: words that went quiet this long without being a question to it are forgotten (side talk).
    static let bargeForget: TimeInterval = 1.5
    static func questionEnded(heard: Bool, quiet: TimeInterval) -> Bool { heard && quiet >= endOfSpeech }
    /// A finished-sounding question ("what do you see", "is the light on") ends after this much quiet instead of
    /// audioQuiet (11/2 speed pass: ~0.35 s sooner on most questions; trailing words still get the longer wait).
    static let audioQuietComplete: TimeInterval = 0.5
    static let trailing: Set<String> = ["and", "the", "a", "an", "to", "of", "in", "on", "at", "with", "my", "your", "is", "are",
                                        "what", "how", "about", "but", "or", "so", "like", "um", "uh", "that", "this", "for", "if",
                                        "because", "then", "hello", "hey", "hi", "okay", "ok", "well", "can", "could", "do", "does"]
    static func looksComplete(_ text: String) -> Bool {
        let w = LiveWords.normalize(text).split(separator: " ")
        guard w.count >= 3, let last = w.last else { return false }
        return !trailing.contains(String(last))
    }
    static func questionEnded(heard: Bool, wordsQuiet: TimeInterval, micQuiet: TimeInterval, text: String = "") -> Bool {
        let quiet = looksComplete(text) ? audioQuietComplete : audioQuiet
        return heard && (wordsQuiet >= endOfSpeech || (micQuiet >= quiet && wordsQuiet >= wordsSettled))
    }
}

/// Talking over it (Matt 11/6): "It shouldn't stop speaking when it hears me cough... murmurs or any sound at all.
/// It should only stop speaking when it hears a legitimate question toward it." The old loudness trigger is gone;
/// only recognized words can interrupt, and only these.
enum LiveBargeIn {
    /// Sounds and fillers the recognizer turns coughs, laughs and murmurs into (English and Spanish).
    static let filler: Set<String> = ["um", "uh", "umm", "uhh", "hmm", "hm", "mm", "mmm", "mhm", "uh-huh", "huh", "ah", "oh", "eh",
                                      "yeah", "yep", "yes", "okay", "ok", "ha", "haha", "hahaha", "heh", "so", "well", "like", "er",
                                      "erm", "the", "a", "and", "oops", "whoa", "wow", "cough", "ahem", "sigh", "i", "it",
                                      "este", "pues", "ajá", "aja", "sí", "si", "bueno", "o", "sea", "ja", "jaja", "el", "la", "y", "eeh"]
    /// Words that stop it ("wait", "stop", "hold on"), wherever they come in what was heard.
    static let stopsEnglish: [[String]] = [["stop"], ["wait"], ["hold", "on"], ["hang", "on"], ["hey"], ["excuse", "me"], ["shh"],
                                    ["shush"], ["be", "quiet"], ["never", "mind"], ["nevermind"], ["one", "sec"], ["one", "second"],
                                    ["live", "cam"], ["quiet"], ["pause"], ["enough"]]
    static let stopsSpanish: [[String]] = [["espera"], ["esperá"], ["para"], ["pará"], ["alto"], ["oye"], ["basta"], ["cállate"],
                                    ["callate"], ["silencio"], ["detente"], ["un", "momento"], ["momento"], ["live", "cam"], ["olvídalo"]]
    /// A question or ask to it: how it opens.
    static let askStartsEnglish: Set<String> = ["what", "whats", "who", "where", "when", "why", "how", "which", "is", "are", "can",
                                         "could", "would", "should", "will", "do", "does", "did", "tell", "describe", "show",
                                         "explain", "help", "look", "read", "check", "find", "give", "say", "repeat"]
    static let askStartsSpanish: Set<String> = ["qué", "cómo", "dónde", "cuál", "cuándo", "quién", "cuánto", "cuántos", "puedes",
                                         "podrías", "podrias", "dime", "mira", "lee", "describe", "ayúdame", "ayudame", "explica",
                                         "busca", "repite", "muéstrame", "muestrame"]
    static let askPhrasesEnglish = [" can you ", " could you ", " would you ", " tell me ", " look at ", " what is ", " what s ", " how do ",
                             " how many ", " where is ", " is this ", " is that ", " what about ", " do you ", " are you "]
    static let askPhrasesSpanish = [" puedes ", " podrías ", " dime ", " mira ", " qué es ", " cómo ", " dónde ", " cuál ",
                                    " me dices ", " qué hay ", " qué ves ", " por qué "]

    /// Spanish words that open a question but are also everyday words ("que", "es", "está"): two of them, or a strong
    /// opener, are needed (review 11/6).
    static let weakSpanish: Set<String> = ["que", "como", "donde", "cual", "cuando", "quien", "cuanto", "cuantos", "por", "hay",
                                           "es", "está", "esta", "tengo"]

    static func isSpanish(_ lang: String) -> Bool { lang.lowercased().hasPrefix("es") }

    /// Marks which of `words` are its own voice: a run of 3+ words in a row matching what it is saying (a whole
    /// short line like "Flashlight, on" counts too). One shared word ("cup") is never an echo (review 11/6).
    static func echoMask(_ words: [String], saying: [String]) -> [Bool] {
        let own = saying.map { LiveWords.normalize($0).split(separator: " ").map(String.init) }
        var echo = [Bool](repeating: false, count: words.count)
        for line in own where !line.isEmpty {
            let need = min(3, line.count, max(2, words.count))   // a 2-word utterance that is 2 of its own words in a row
            var i = 0
            while i < words.count {
                var best = 0
                for j in 0 ..< line.count {
                    var k = 0
                    while i + k < words.count, j + k < line.count, words[i + k] == line[j + k] { k += 1 }
                    best = max(best, k)
                }
                if best >= need { for x in i ..< i + best { echo[x] = true }; i += best } else { i += 1 }
            }
        }
        return echo
    }

    /// The words heard minus its own voice (review 11/6 round 2: everything echoed is taken out, so its own
    /// "Flashlight, on" or "hold on" heard back never counts as a command).
    static func withoutEcho(_ words: [String], saying: [String]) -> [String] {
        let echo = echoMask(words, saying: saying)
        return words.indices.filter { !echo[$0] }.map { words[$0] }
    }

    /// A barged-in question with its own voice left out: only an echo at the START is stripped, matched on the text
    /// itself (raw words, so "cup's" stays one word), never words after the question ("what is that, the cup is red").
    static func stripLeadingEcho(_ transcript: String, saying: [String]) -> String {
        let raw = transcript.split(separator: " ").map(String.init)
        guard !raw.isEmpty else { return transcript }
        // Each raw word's normalized words, so the echo is found on normalized text and cut on raw word edges.
        let parts = raw.map { LiveWords.normalize($0).split(separator: " ").map(String.init) }
        let flat = parts.flatMap { $0 }
        let echo = echoMask(flat, saying: saying)
        var cut = 0, at = 0
        for p in parts {
            let n = p.count
            if n == 0 { if cut == raw.count { break }; cut += 1; continue }   // punctuation on its own rides along
            guard (at ..< at + n).allSatisfy({ echo[$0] }) else { break }
            at += n; cut += 1
        }
        guard cut > 0 else { return transcript }
        return raw.dropFirst(cut).joined(separator: " ")
    }

    /// True only for real words meant for it, judged on the words left once its own voice is taken out: a light or
    /// stop command anywhere in them, or a question/ask of at least three real words, not filler, not low
    /// confidence. `continuing`: they started talking again right after their question ended, so two real words are
    /// enough. `lang`: the language being heard (the recognizer's).
    static func shouldInterrupt(_ heard: String, confidence: Double?, saying: [String], continuing: Bool = false,
                                lang: String = "en") -> Bool {
        if let c = confidence, c > 0, c < 0.3 { return false }
        let words = LiveWords.normalize(heard).split(separator: " ").map(String.init)
        let fresh = withoutEcho(words, saying: saying)
        let freshText = fresh.joined(separator: " ")
        if LiveWords.lightCommand(freshText) != nil, fresh.count >= 2 { return true }   // "lights on", never its own line
        let es = isSpanish(lang)
        // A stop word anywhere in what they said ("wait, what is the red one", "... hold on").
        let content = fresh.filter { !filler.contains($0) }
        func has(_ ws: [String], _ p: [String]) -> Bool {
            ws.count >= p.count && (0 ... ws.count - p.count).contains { Array(ws[$0 ..< $0 + p.count]) == p }
        }
        // "para" is also "for" in Spanish: it stops only when it opens what was heard ("para, para").
        if (es ? stopsSpanish : stopsEnglish).contains(where: { $0 == ["para"] ? content.first == "para" : has(content, $0) }) { return true }
        let real = content
        if continuing { return real.count >= 2 }
        guard real.count >= 3 else { return false }
        let start = Array(fresh.drop(while: { filler.contains($0) }))
        let t = " " + start.joined(separator: " ") + " "
        if es {
            if heard.contains("¿") { return true }
            if let first = start.first, askStartsSpanish.contains(first) { return true }
            // Two different weak cues, one of them a question word ("donde esta mi taza"), not "que bueno que...".
            let cues = Set(start.prefix(3).filter { weakSpanish.contains($0) })
            if cues.count >= 2, !cues.isDisjoint(with: ["que", "como", "donde", "cual", "cuando", "quien", "cuanto", "cuantos", "por"]) { return true }
            return askPhrasesSpanish.contains { t.contains($0) }
        }
        if let first = start.first, askStartsEnglish.contains(first) { return true }
        return askPhrasesEnglish.contains { t.contains($0) }
    }
}

/// When it may speak up on its own: only when the view really changed, never over the person,
/// at least `minGap` apart, and quiet after `maxUnanswered` comments nobody answered until the
/// view changes a lot or the person talks.
/// Matt 11/09: "it's got to kind of always be taking photos and analyzing them, kind of constantly ... if it sees a
/// dog, it says, oh, now I see a dog". The fast detector looks at the camera every second or so; a thing it has never
/// told about, seen on two checks in a row (so a blur doesn't count), gets one short line, at most one line every
/// few seconds. A question or a goal pauses it: he speaks, that comes first.
struct LiveNovelty {
    static let stableChecks = 2
    static let minGap: TimeInterval = 7
    /// Detector checks: about every second, slower when the phone runs hot.
    static func interval(_ thermal: ProcessInfo.ThermalState) -> TimeInterval? {
        switch thermal {
        case .nominal, .fair: 1.0
        case .serious: 3.0
        case .critical: nil   // the detector rests; questions still work
        @unknown default: 3.0
        }
    }

    /// What was in view when watching started: there already, so never "new".
    private(set) var known: Set<String> = []
    private(set) var baselined = false
    private(set) var streak: [String: Int] = [:]
    private(set) var lastLine = Date.distantPast
    /// A question is being heard or answered, or a goal is on.
    var paused = false

    /// Labels from one detector check. Returns the ones to announce now: not told, not there at the start, seen on
    /// `stableChecks` checks in a row, while not paused.
    mutating func observe(_ labels: [String], isNew: (String) -> Bool) -> [String] {
        let here = Set(labels.map { LiveWords.normalize($0) }.filter { !$0.isEmpty })
        guard baselined else { known = here; baselined = true; return [] }
        guard !paused else { streak = [:]; return [] }
        let fresh = here.filter { !known.contains($0) && isNew($0) }
        streak = streak.filter { fresh.contains($0.key) }   // in a row, or it starts over
        for l in fresh { streak[l, default: 0] += 1 }
        return fresh.filter { (streak[$0] ?? 0) >= Self.stableChecks }.sorted()
    }

    func canSpeak(at t: Date) -> Bool { !paused && t.timeIntervalSince(lastLine) >= Self.minGap }

    /// One line said about `label`: it is known from now on.
    mutating func announced(_ label: String, at t: Date) {
        known.insert(LiveWords.normalize(label)); streak[LiveWords.normalize(label)] = nil; lastLine = t
    }

    /// Any other unprompted line counts toward the gap too.
    mutating func spoke(at t: Date) { lastLine = t }

    /// A new room: start over (the next check is the new baseline).
    mutating func reset() { known = []; baselined = false; streak = [:] }
}

struct LiveProactive {
    static let minGap: TimeInterval = 3   // 11/1 Matt: it never spoke up in a 25 s call (was 10 s, 30 and 50 below)
    /// Two comments with no reply, then quiet until a big change (Matt, 10/31).
    static let maxUnanswered = 2
    /// Mean absolute difference (0...255) of a 16x16 gray thumbnail.
    /// Someone moving or pulling faces in the same room is not a new scene: only a real change of view.
    static let changed: Double = 14
    static let bigChange: Double = 30

    var enabled = true
    private(set) var lastComment = Date.distantPast
    private(set) var unanswered = 0
    private(set) var reference: [UInt8]?
    /// How different the last checked view was (for the log).
    private(set) var lastDifference: Double = 0

    /// The view the last description was about.
    mutating func described(_ thumb: [UInt8]) { reference = thumb }

    mutating func personSpoke() { unanswered = 0 }

    mutating func commented(at t: Date) { lastComment = t; unanswered += 1 }

    /// Normal mode: quiet this long (no one talking, nothing said) before a friendly check-in.
    static let checkInAfter: TimeInterval = 90
    /// Check in only when the person has been quiet a good while, and at most twice in a row with no reply.
    /// `evenIfOff`: a goal's own check-in, which the person started by naming the job.
    func shouldCheckIn(at t: Date, quietSince: Date, after: TimeInterval = checkInAfter, evenIfOff: Bool = false) -> Bool {
        (enabled || evenIfOff) && unanswered < Self.maxUnanswered && t.timeIntervalSince(max(quietSince, lastComment)) >= after
    }
    /// With a goal (Matt 11/6) the check-in comes sooner: they're in the middle of a job.
    static let goalCheckInAfter: TimeInterval = 45

    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var s = 0
        for i in 0 ..< a.count { s += abs(Int(a[i]) - Int(b[i])) }
        return Double(s) / Double(a.count)
    }

    /// Worth running the model for a look? (Cheap: called every couple of seconds.)
    mutating func shouldLook(thumb: [UInt8], at t: Date, quiet: Bool) -> Bool {
        // Not behind the "Speak up when quiet" switch (that is check-ins only): new things are always told (Matt 11/09).
        guard quiet, t.timeIntervalSince(lastComment) >= Self.minGap else { return false }
        guard let ref = reference else { return true }
        let d = Self.difference(thumb, ref)
        lastDifference = d
        if unanswered >= Self.maxUnanswered {
            guard d >= Self.bigChange else { return false }
            unanswered = 0
        }
        return d >= Self.changed
    }
}

// MARK: - Modes (Matt 11/1)

/// How Live camera talks. Switched by voice; remembered between sessions.
enum LiveMode: String, CaseIterable, Equatable, Sendable {
    case normal, funny, analyze, coach

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .funny: return "Funny"
        case .analyze: return "Analyze"
        case .coach: return "Coach"
        }
    }

    /// Said when the mode turns on.
    var confirm: String {
        switch self {
        case .normal: return "Back to normal."
        case .funny: return "Funny mode on."
        case .analyze: return "Analyze mode on. Ask me anything and I'll dig into the how and why."
        case .coach: return "Coach mode on. What do you want coaching on?"
        }
    }

    /// Added to the question itself: the 2B model ignored style rules in the system prompt but follows them here
    /// (tested on the Mac with real frames, 11/1). 11/3 Matt: Coach always went back to posture and Analyze only
    /// listed objects ("you can't ask it about other things, like forces"). Coach now coaches whatever they picked;
    /// Analyze digs into whatever they asked, and only does the full close look when that is what they asked for.
    func ask(_ question: String?, coachGoal: String?) -> String {
        switch self {
        case .normal: return " Leave out the person and their clothes unless the question is about them."   // 11/2: the 2B follows rules on the question, not the system prompt
        case .funny:
            // 11/3 Matt: "funny to take questions and joke about what you tell it too", not only about the view.
            return " Be funny: really answer what they asked or said, then add one playful joke or witty line about what they told you (about what you see only when they asked about the view). Tease the situation, never anyone's looks. Two short sentences."
        case .analyze:
            if question == nil || LiveWords.isLookCloser(question ?? "") {
                return " Be detailed: name the main objects, colors and materials, read any visible text word for word, count anything countable, and say what you can't make out. Three or four sentences."
            }
            // 11/3 Mac test: "the numbers if you can work them out" got invented physics (a bike stays up by "rolling resistance").
            return " Think it through: answer the question first in plain words, then give the main reason why in two or three short sentences, the real, well-known explanation a good teacher would give. Use what you see when it helps. Never make up numbers or facts; if you aren't sure, say so."
        case .coach:
            let topic = coachGoal.map { " They want coaching on \($0)." } ?? ""
            return topic + " Answer like a good coach: one specific, practical tip for what they asked, based on what you see them doing if it's in view, and how to practice it. Encouraging, two short sentences. Leave out their looks and clothes unless they ask."
        }
    }

    var maxTokens: Int { self == .analyze ? 170 : 90 }
}

