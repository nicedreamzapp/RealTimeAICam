import Foundation

/// How the text reader and the translator speak (Matt, 2026-10-23: "we want all
/// phones"). One small button next to Speak cycles through the three. Android
/// has the same three, with the same words.
enum ReadMode: String, CaseIterable {
    /// Today's behavior: nothing is said until Speak is tapped.
    case tap
    /// New, steady text is spoken by itself, once.
    case auto
    /// Text stays on screen only. Speak still works when tapped.
    case mute

    static let storageKey = "ocrReadMode"

    /// What the button is called, said out loud and given to VoiceOver as its value.
    var title: String {
        switch self {
        case .tap: "Tap to read"
        case .auto: "Auto read"
        case .mute: "Mute"
        }
    }

    var symbol: String {
        switch self {
        case .tap: "hand.tap.fill"
        case .auto: "speaker.wave.2.fill"
        case .mute: "speaker.slash.fill"
        }
    }

    var next: ReadMode {
        switch self {
        case .tap: .auto
        case .auto: .mute
        case .mute: .tap
        }
    }

    static var saved: ReadMode {
        ReadMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .tap
    }
}

/// Decides when Auto read speaks. The camera re-reads the page about once a
/// second and the words wobble every time (a letter dropped, a line lost at the
/// edge, the order of two lines swapped), so "the text changed" is not a reason
/// to talk. Speak only when:
///   1. the text has been steady for `stableFor` seconds, where steady means each
///      new read is nearly the same words as the one it replaced, and
///   2. it is meaningfully different from the last thing spoken.
/// Pure logic with the clock passed in, so the unit tests can drive it.
struct AutoReadGate {
    /// How long the words must hold still before they are read.
    var stableFor: TimeInterval = 1.0
    /// Two reads at least this alike are the same text wobbling.
    var sameTextSimilarity: Double = 0.75

    private(set) var candidate = ""
    private(set) var candidateSince = Date.distantPast
    private(set) var lastSpoken = ""

    /// A new read from the camera (or a new translation).
    mutating func observe(_ text: String, at now: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            candidate = ""
            candidateSince = now
            return
        }
        if !candidate.isEmpty, Self.similarity(trimmed, candidate) >= sameTextSimilarity {
            // Same page, wobbling. Keep the clock running, keep the fuller read.
            if Self.words(trimmed).count >= Self.words(candidate).count { candidate = trimmed }
            return
        }
        candidate = trimmed
        candidateSince = now
    }

    /// The text to speak now, or nil. Call when a read arrives, when the steady
    /// timer runs out, and when speaking finishes.
    func textToSpeak(at now: Date) -> String? {
        guard Self.words(candidate).count >= 1,
              Self.normalized(candidate).count >= 2,
              now.timeIntervalSince(candidateSince) >= stableFor else { return nil }
        if !lastSpoken.isEmpty, Self.isSameText(candidate, as: lastSpoken, threshold: sameTextSimilarity) {
            return nil
        }
        return candidate
    }

    /// When the steady timer for the current candidate runs out.
    var readyAt: Date { candidateSince.addingTimeInterval(stableFor) }

    /// Something was said (by Auto read or by tapping Speak), so it is not new any more.
    mutating func markSpoken(_ text: String) {
        lastSpoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Forget everything, e.g. the mode was switched or the language changed.
    mutating func reset() {
        candidate = ""
        candidateSince = .distantPast
        lastSpoken = ""
    }

    // MARK: - Text comparison

    static func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    static func words(_ text: String) -> [String] {
        normalized(text).split(separator: " ").map(String.init)
    }

    /// Dice coefficient over the multiset of words: 1 = same words, 0 = none shared.
    /// Word order is ignored on purpose, since OCR swaps lines between reads.
    static func similarity(_ a: String, _ b: String) -> Double {
        let wa = words(a), wb = words(b)
        if wa.isEmpty && wb.isEmpty { return 1 }
        if wa.isEmpty || wb.isEmpty { return 0 }
        var counts: [String: Int] = [:]
        for w in wa { counts[w, default: 0] += 1 }
        var shared = 0
        for w in wb where (counts[w] ?? 0) > 0 {
            counts[w]! -= 1
            shared += 1
        }
        return 2.0 * Double(shared) / Double(wa.count + wb.count)
    }

    /// Same text as what was already said: nearly the same words, or a piece of
    /// it (the camera lost a line or the edge of the page). A read that only
    /// ADDS words keeps most of the old ones, so it counts as new only when the
    /// additions are a real part of it.
    static func isSameText(_ text: String, as spoken: String, threshold: Double) -> Bool {
        if similarity(text, spoken) >= threshold { return true }
        let wt = words(text)
        guard !wt.isEmpty else { return true }
        var counts: [String: Int] = [:]
        for w in words(spoken) { counts[w, default: 0] += 1 }
        var contained = 0
        for w in wt where (counts[w] ?? 0) > 0 {
            counts[w]! -= 1
            contained += 1
        }
        // 90% of this read was already spoken: it is a fragment of the old page.
        return Double(contained) / Double(wt.count) >= 0.9
    }
}

#if DEBUG
/// Simulator proof for Auto read: every line the reader speaks goes into
/// Documents/speak_log.txt so a test can count them. Debug builds only.
enum SpeakLog {
    static func note(_ source: String, _ text: String) {
        let line = "\(String(format: "%.2f", Date().timeIntervalSince1970)) \(source): \(text)\n"
        print("[SpeakLog] \(source): \(text)")
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("speak_log.txt")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
#endif
