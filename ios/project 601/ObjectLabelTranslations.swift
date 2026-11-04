import CryptoKit
import Foundation

/// Object Detection names in Your language (2026-11-04). The detector gives a class
/// number; its English name is translated ONCE per language with Apple's on-device
/// translator (after that language is downloaded), saved to a file, and read from the
/// file from then on: instant and offline.
///
/// A bare word is ambiguous to a translator ("mouse" the animal or the computer one,
/// "glasses" to see with or to drink from, "stool" to sit on...). `context` gives the
/// phrase that is translated instead; a note in brackets is dropped from the answer.
/// Built by reading every one of the 601 labels in class_names.txt; the same map as
/// Android ObjectLabelTranslations.kt.
enum ObjectLabelTranslations {
    /// Bump when `context` changes, so saved files are rebuilt.
    static let mapVersion = 3

    /// Names fixed by hand, used as is and never sent to the translator (2026-11-04: Matt
    /// wants a cup said as just "taza"; the detector calls every cup "Coffee cup").
    /// Same map as Android ObjectLabelTranslations.EXACT.
    static let exact: [String: [String: String]] = [
        "es": ["Cup": "taza", "Mug": "taza", "Coffee cup": "taza", "Measuring cup": "taza medidora"],
    ]

    static let context: [String: String] = [
        "Mouse": "mouse (animal)",
        "Computer mouse": "computer mouse",
        "Bat (Animal)": "bat (flying animal)",
        "Baseball bat": "baseball bat",
        "Glasses": "eyeglasses",
        "Wine glass": "wine glass",
        "Tie": "necktie",
        "Kite": "kite (toy)",
        "Orange": "orange (fruit)",
        "Ruler": "ruler (measuring tool)",
        "Stool": "stool (seat)",
        "Watch": "wristwatch",
        "Scale": "weighing scale",
        "Tank": "tank (military vehicle)",
        "Tap": "water tap",
        "Turkey": "turkey (bird)",
        "Torch": "flaming torch",
        "Tick": "tick (parasite)",
        "Mixer": "kitchen mixer",
        "Boot": "boot (footwear)",
        "Bust": "bust (sculpture)",
        "Fax": "fax machine",
        "Paddle": "canoe paddle",
        "Pen": "ballpoint pen",
        "Cream": "cream (dairy)",
        "Rose": "rose (flower)",
        "Sink": "sink (basin)",
        "Mule": "mule (animal)",
        "Suit": "suit (clothing)",
        "Tart": "tart (pastry)",
        "Chime": "wind chime",
        "Table": "table (furniture)",
        "Cart": "cart (wagon)",
        "Grinder": "grinder (power tool)",
        "Harbor seal": "harbor seal",
        "Football": "football (ball)",
        "Ball": "ball (toy)",
        "Mechanical fan": "electric fan",
        "Willow": "willow tree",
        "Maple": "maple tree",
        "Jaguar (Animal)": "jaguar (animal)",
        "Drill (Tool)": "drill (tool)",
        "Egg (Food)": "egg (food)",
        "Nail (Construction)": "nail (construction)",
        "Organ (Musical Instrument)": "pipe organ",
        "Pitcher (Container)": "water pitcher",
        "Ratchet (Device)": "ratchet wrench",
        "Squash (Plant)": "squash (vegetable)",
        "Volleyball (Ball)": "volleyball (ball)",
        "Lavender (Plant)": "lavender (plant)",
        "Rays and skates": "rays and skates (fish)",
        "Jug": "jug (container)",
        "Racket": "racket (sport)",
        "Plant": "plant (vegetation)",
        "Glove": "glove (clothing)",
        "Remote control": "remote control",
        "Ipod": "iPod",
        "Light bulb": "light bulb",
        "Microwave oven": "microwave oven",
        "Tablet computer": "tablet computer",
    ]

    /// Said with LiDAR distances ("perro a la izquierda 3 pies"), translated with the names.
    static let extras = ["to the left", "to the right", "in the center", "feet"]

    /// The English phrase the translator sees for a label.
    static func sourcePhrase(_ label: String) -> String { context[label] ?? label.lowercased() }

    /// The translator's answer, without any note in brackets, trimmed.
    static func cleanOutput(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*[(（\[][^)）\]]*[)）\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Leading articles a translator adds to a bare noun ("los anteojos", "la souris").
    private static let articles: [String: String] = [
        "es": "^(el|la|los|las|un|una|unos|unas) ",
        "fr": "^((le|la|les|un|une|des) |l['’])",
        "de": "^(der|die|das|ein|eine) ",
        "it": "^((il|lo|la|i|gli|le|un|uno|una) |l['’]|un['’])",
        "pt": "^(o|a|os|as|um|uma) ",
        "nl": "^(de|het|een) ",
    ]

    /// `cleanOutput`, then without a leading article for `lang`.
    static func cleanOutput(_ s: String, lang: String) -> String {
        let c = cleanOutput(s)
        guard let pattern = articles[lang],
              let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return c }
        let range = NSRange(c.startIndex..., in: c)
        let out = re.stringByReplacingMatches(in: c, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? c : out
    }

    /// Changes when the label list or the context map changes.
    static func signature(_ labels: [String]) -> String {
        var data = Data("v\(mapVersion)\n".utf8)
        for l in labels { data.append(Data(l.utf8)); data.append(0) }
        for k in context.keys.sorted() { data.append(Data("\(k)=\(context[k]!)".utf8)); data.append(0) }
        for (lang, names) in exact.sorted(by: { $0.key < $1.key }) {
            for k in names.keys.sorted() { data.append(Data("\(lang):\(k)=\(names[k]!)".utf8)); data.append(0) }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    struct File: Codable, Equatable {
        let lang: String
        let signature: String
        let labels: [String]
    }

    static func cacheURL(_ dir: URL, lang: String) -> URL { dir.appendingPathComponent("labels_\(lang).json") }

    static func serialize(lang: String, signature: String, translated: [String]) -> Data {
        (try? JSONEncoder().encode(File(lang: lang, signature: signature, labels: translated))) ?? Data()
    }

    /// The saved names, or nil when the file is missing, damaged or for another list.
    static func parse(_ data: Data, lang: String, signature: String, expectedCount: Int) -> [String]? {
        guard let f = try? JSONDecoder().decode(File.self, from: data),
              f.lang == lang, f.signature == signature, f.labels.count == expectedCount else { return nil }
        return f.labels
    }

    static func load(_ dir: URL, lang: String, labels: [String]) -> [String]? {
        guard let data = try? Data(contentsOf: cacheURL(dir, lang: lang)) else { return nil }
        return parse(data, lang: lang, signature: signature(labels), expectedCount: labels.count)
    }

    /// Saved names, or translate all of them once (`translate` gets the English phrases,
    /// answers in the same order, nil for a failure) and save them. Returns nil if any
    /// failed, so a half-built list is never saved; the caller keeps English and tries
    /// again next time.
    static func loadOrBuild(_ dir: URL, lang: String, labels: [String],
                            translate: ([String]) async -> [String?]) async -> [String]? {
        if let saved = load(dir, lang: lang, labels: labels) { return saved }
        let answers = await translate(labels.map(sourcePhrase))
        guard answers.count == labels.count else { return nil }
        var out: [String] = []
        out.reserveCapacity(labels.count)
        for (label, answer) in zip(labels, answers) {
            if let fixed = exact[lang]?[label] { out.append(fixed); continue }
            guard let answer else { return nil }
            let c = cleanOutput(answer, lang: lang)
            out.append(c.isEmpty ? label.lowercased() : c)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? serialize(lang: lang, signature: signature(labels), translated: out)
            .write(to: cacheURL(dir, lang: lang), options: .atomic)
        return out
    }
}

/// The names Object Detection says right now. English until Your language's list is
/// built; reads are lock-protected so the speech queue can ask from any thread.
final class ObjectLabelCache: @unchecked Sendable {
    static let shared = ObjectLabelCache()

    private let lock = NSLock()
    private var lang = YourLanguageRules.english
    private var names: [String: String] = [:]
    private var building: String?
    private var lastStatus = "object names: English"
    /// "object names: es 605 from file in 9 ms" (logs and simulator tests).
    var status: String { lock.lock(); defer { lock.unlock() }; return lastStatus }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("YourLanguage", isDirectory: true)
    }

    static let labels: [String] = {
        guard let path = Bundle.main.path(forResource: "class_names", ofType: "txt"),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }()

    /// The name to say for a detector class, in Your language when its list is ready.
    func name(for className: String) -> String? {
        let active = YourLanguage.activeCode
        guard active != YourLanguageRules.english else { return nil }
        lock.lock(); defer { lock.unlock() }
        return lang == active ? names[className] : nil
    }

    /// Load (or build once) the list for `code`. Safe to call repeatedly.
    func prepare(_ code: String) {
        guard code != YourLanguageRules.english else { return }
        lock.lock()
        if lang == code || building == code { lock.unlock(); return }
        building = code
        lock.unlock()
        let all = Self.labels + ObjectLabelTranslations.extras
        Task.detached(priority: .utility) { [weak self] in
            let start = Date()
            let fromFile = ObjectLabelTranslations.load(Self.directory, lang: code, labels: all) != nil
            let built = await ObjectLabelTranslations.loadOrBuild(Self.directory, lang: code, labels: all) { phrases in
                await YourLanguageTranslator.shared.translateMany(phrases, from: YourLanguageRules.english, to: code)
            }
            guard let self else { return }
            lock.lock()
            building = nil
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if let built {
                names = Dictionary(zip(all, built), uniquingKeysWith: { a, _ in a })
                lang = code
                lastStatus = "object names: \(code) \(built.count) \(fromFile ? "from file" : "built") in \(ms) ms"
            } else {
                lastStatus = "object names: \(code) failed"
            }
            let status = lastStatus
            lock.unlock()
            NSLog("YourLanguage: %@", status)
            #if DEBUG
            SpeakLog.note("objectNames", status + (built.map { " mouse=\($0[all.firstIndex(of: "Mouse") ?? 0]) computer mouse=\($0[all.firstIndex(of: "Computer mouse") ?? 0])" } ?? ""))
            #endif
        }
    }
}
