import Foundation

/// Whole-sentence and whole-clause Spanish idioms, matched BEFORE the system
/// translator so sayings it renders word for word come out as the English saying:
/// "No hay mal que por bien no venga" → "Every cloud has a silver lining".
/// Only a complete sentence, or a complete clause,
/// is ever replaced (clauses split at commas and semicolons); single words are never patched. Same rules as Android's
/// SpanishIdiomPrepass.kt; the list is es_idioms.json (tools/make-es-idioms.py).
enum SpanishIdiomPrepass {
    enum Piece: Equatable {
        case fixed(String)      // already English (an idiom)
        case translate(String)  // Spanish for the translator
    }

    static let idioms: [String: String] = {
        guard let url = Bundle.main.url(forResource: "es_idioms", withExtension: "json")
                ?? Bundle(for: BundleToken.self).url(forResource: "es_idioms", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }()
    private final class BundleToken {}

    /// Lowercase, accents folded, punctuation to spaces, spaces collapsed.
    static func normalize(_ s: String) -> String {
        let folded = s.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
        let spaced = String(folded.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : " " })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    /// Sentences, each with its own trailing punctuation and spacing kept.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if ".!?…\n".contains(c) {
                // keep closing punctuation and the spaces that follow with this sentence
                while i + 1 < chars.count, ".!?…\"”»)".contains(chars[i + 1]) { i += 1; current.append(chars[i]) }
                while i + 1 < chars.count, chars[i + 1].isWhitespace { i += 1; current.append(chars[i]) }
                out.append(current); current = ""
            }
            i += 1
        }
        if !current.isEmpty { out.append(current) }
        chars.removeAll()
        return out
    }

    private static func english(for spanish: String) -> String? {
        let key = normalize(spanish)
        guard key.split(separator: " ").count >= 3 else { return nil }
        return idioms[key]
    }

    /// Re-dress an idiom's English in the source's capital and punctuation.
    private static func dress(_ english: String, like source: String) -> String {
        var e = english
        if let f = source.first(where: { $0.isLetter }), f.isUppercase, let first = e.first {
            e = first.uppercased() + e.dropFirst()
        }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = trimmed.reversed().prefix { !$0.isLetter && !$0.isNumber && !"¿¡".contains($0) }
        let lead = source.prefix { $0.isWhitespace }
        let trail = source.reversed().prefix { $0.isWhitespace }
        let punct = String(tail.reversed()).replacingOccurrences(of: "¿", with: "").replacingOccurrences(of: "¡", with: "")
        return String(lead) + e + punct + String(trail.reversed())
    }

    /// Split text into idiom pieces and pieces for the translator. Neighbouring
    /// translator pieces are merged so the translator keeps its context.
    static func plan(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        func add(_ p: Piece) {
            if case .translate(let s) = p, case .translate(let prev)? = pieces.last {
                pieces[pieces.count - 1] = .translate(prev + s)
            } else { pieces.append(p) }
        }
        for sentence in sentences(text) {
            if let e = english(for: sentence) { add(.fixed(dress(e, like: sentence))); continue }
            // Clauses, each keeping its own separator.
            var clauses: [String] = []
            var cur = ""
            for c in sentence {
                cur.append(c)
                if ",;".contains(c) { clauses.append(cur); cur = "" }
            }
            if !cur.isEmpty { clauses.append(cur) }
            if clauses.count > 1, clauses.contains(where: { english(for: $0) != nil }) {
                for clause in clauses {
                    if let e = english(for: clause) { add(.fixed(dress(e, like: clause))) } else { add(.translate(clause)) }
                }
            } else {
                add(.translate(sentence))
            }
        }
        return pieces
    }

    /// Run the plan: idiom pieces as they are, the rest through `translate`.
    static func translate(_ text: String, using translate: (String) async throws -> String) async throws -> String {
        var out = ""
        for piece in plan(text) {
            switch piece {
            case .fixed(let e): out += e
            case .translate(let s):
                let core = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if core.isEmpty || !core.contains(where: { $0.isLetter }) { out += s; continue }
                let lead = s.prefix { $0.isWhitespace }
                let trail = String(s.reversed().prefix { $0.isWhitespace }.reversed())
                if !out.isEmpty, lead.isEmpty, let last = out.last, !last.isWhitespace { out += " " }
                out += lead + (try await translate(core)) + trail
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
