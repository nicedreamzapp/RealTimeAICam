// Live Cam, the pure part: what is said, when, and what is remembered. Plain logic, no camera,
// mic or model, so it is unit tested (LiveBrainTests). Ported 2026-11-04 from Moonstone's Live camera
// (divine-tribe-hq shared/moonstone-ios/App/LiveCamera/LiveBrain.swift), which was first ported from RT Cam's
// Talk mode. Every tuning note below is Matt's, kept as is; only the name (Live Cam, not Moonstone) and the
// blind-first line in the prompts are new.
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
    func vet(_ sentence: String) -> String? {
        var s = Self.cutLoop(sentence).trimmingCharacters(in: .whitespaces)
        guard !LiveWords.normalize(s).isEmpty else { return nil }
        if helpOffered, LiveWords.isHelpOffer(s) { return nil }
        if said.contains(LiveWords.normalize(s)) { return nil }
        if let last = lastOpening, Self.opening(s) == last || (last.hasPrefix("i see") && Self.opening(s).hasPrefix("i see")) { s = Self.reworded(s) }
        if said.contains(LiveWords.normalize(s)) { return nil }
        return s
    }

    /// Remember a line that is being said (model sentences and the app's own lines alike).
    mutating func note(_ line: String) {
        let n = LiveWords.normalize(line)
        guard !n.isEmpty else { return }
        said.insert(n)
        lastOpening = Self.opening(line)
        if LiveWords.isHelpOffer(line) { helpOffered = true }
    }

    /// The new-thing line for now: the one help offer if it hasn't been made, else just the thing, never opening
    /// with "I see" twice in a row.
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
    /// Says out loud that it is always listening: there is nothing to tap (Matt's first try, 10/31).
    /// 11/2 Matt: "it should just be like hey there how you doing and then wait for cues", not describe the room.
    static let greeting = "Hey there, how's it going?"
    /// The first greeting of each visit. Matt 11/6: "what is that warning welcome I don't want that": no welcome, no
    /// experimental warning spoken at open, just the plain greeting (the Home button still says experimental).
    static let firstGreeting = greeting
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

    /// The one look at the start of a call: what's around, never the person (11/2 Matt).
    /// Matt 11/6: "I see a map and a monitor". The one help offer of the visit is added by the code after it
    /// (LiveCamWords.helpOffer), never asked of the model, so it can't come back on every look.
    static let openingLook = "In one short sentence that starts with \"I see\", name the main things around here. Never mention the person, their face or clothes."
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
                           "critique me", "rate me", "roast me", "judge me", "how i look", "my posture", "wait", "shh", "shush", "quiet", "hang on", "never mind", "nevermind"]

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
        if ["repeat", "repeat that", "say that again", "what did you say", "come again", "say it again"].contains(t) { return .repeatLast }
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
    /// Sounds and fillers the recognizer turns coughs, laughs and murmurs into.
    static let filler: Set<String> = ["um", "uh", "umm", "uhh", "hmm", "hm", "mm", "mmm", "mhm", "uh-huh", "huh", "ah", "oh", "eh",
                                      "yeah", "yep", "yes", "okay", "ok", "ha", "haha", "hahaha", "heh", "so", "well", "like", "er",
                                      "erm", "the", "a", "and", "oops", "whoa", "wow", "cough", "ahem", "sigh", "i", "it"]
    /// Words that stop it when they open what was said ("wait", "stop", "hold on").
    static let stops: [[String]] = [["stop"], ["wait"], ["hold", "on"], ["hang", "on"], ["hey"], ["excuse", "me"], ["shh"],
                                    ["shush"], ["be", "quiet"], ["never", "mind"], ["nevermind"], ["one", "sec"], ["one", "second"],
                                    ["live", "cam"], ["quiet"], ["pause"], ["enough"]]
    /// A question or ask to it: how it opens.
    static let askStarts: Set<String> = ["what", "whats", "who", "where", "when", "why", "how", "which", "is", "are", "can", "could",
                                         "would", "should", "will", "do", "does", "did", "tell", "describe", "show", "explain", "help",
                                         "look", "read", "check", "find", "give", "say", "repeat"]
    static let askPhrases = [" can you ", " could you ", " would you ", " tell me ", " look at ", " what is ", " what s ", " how do ",
                             " how many ", " where is ", " is this ", " is that ", " what about ", " do you ", " are you "]

    /// True only for real words meant for it: a stop word opening what was said, or a question/ask of at least three
    /// words that are not its own voice coming back, not filler, and not low confidence. `saying`: what it is saying
    /// now (its own words heard through the speaker never count). `continuing`: they started talking again right after
    /// their question ended, so two real words are enough (they weren't done).
    static func shouldInterrupt(_ heard: String, confidence: Double?, saying: [String], continuing: Bool = false) -> Bool {
        if let c = confidence, c > 0, c < 0.3 { return false }
        if LiveWords.lightCommand(heard) != nil, LiveWords.normalize(heard).split(separator: " ").count >= 2 { return true }   // "lights on"
        let own = Set(saying.flatMap { LiveWords.normalize($0).split(separator: " ").map(String.init) })
        let words = LiveWords.normalize(heard).split(separator: " ").map(String.init)
        // Its own voice: the words that are not in what it is saying right now.
        let fresh = words.filter { !own.contains($0) }
        let real = fresh.filter { !filler.contains($0) }
        guard !real.isEmpty else { return false }
        // Most of what was heard is its own sentence coming back through the speaker: never a barge-in.
        if !own.isEmpty, Double(fresh.count) / Double(max(1, words.count)) < 0.5, words.count >= 3 { return false }
        // A stop word opening what was heard, unless it is in what it is saying ("hold on" said by it, heard back).
        let opening = Array(words.drop(while: { filler.contains($0) }))
        let ownLine = " " + saying.map { LiveWords.normalize($0) }.joined(separator: " ") + " "
        if stops.contains(where: { opening.count >= $0.count && Array(opening.prefix($0.count)) == $0
            && !ownLine.contains(" " + $0.joined(separator: " ") + " ") }) { return true }
        let start = Array(fresh.drop(while: { filler.contains($0) }))
        let meaningful = real
        if continuing { return meaningful.count >= 2 }
        guard meaningful.count >= 3 else { return false }
        let t = " " + start.joined(separator: " ") + " "
        if let first = start.first, askStarts.contains(first) { return true }
        return askPhrases.contains { t.contains($0) }
    }
}

/// When it may speak up on its own: only when the view really changed, never over the person,
/// at least `minGap` apart, and quiet after `maxUnanswered` comments nobody answered until the
/// view changes a lot or the person talks.
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
    func shouldCheckIn(at t: Date, quietSince: Date) -> Bool {
        enabled && unanswered < Self.maxUnanswered && t.timeIntervalSince(max(quietSince, lastComment)) >= Self.checkInAfter
    }

    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var s = 0
        for i in 0 ..< a.count { s += abs(Int(a[i]) - Int(b[i])) }
        return Double(s) / Double(a.count)
    }

    /// Worth running the model for a look? (Cheap: called every couple of seconds.)
    mutating func shouldLook(thumb: [UInt8], at t: Date, quiet: Bool) -> Bool {
        guard enabled, quiet, t.timeIntervalSince(lastComment) >= Self.minGap else { return false }
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

