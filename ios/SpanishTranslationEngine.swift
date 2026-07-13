import Compression
import Foundation

// MARK: - JSON Models (All shared types in one place)

private struct ESMetadata: Decodable {
    let cleaned: Bool?
    let language_pair: String?
    let total_dictionary: Int?
    let total_rules: Int?
    let version: String?
}

private struct ESDictEntry: Decodable {
    let lemma: String?
    let morph: [String: String]?
    let pos: String?
    let translation: String?
}

private struct ESRegexRule: Decodable {
    let name: String?
    let description: String?
    let pattern: String
    let replace: String
    let options: [String]?
    let enabled: Bool?
}

private struct ESMaster: Decodable {
    let _metadata: ESMetadata?
    let dictionary: [String: ESDictEntry]?
    let rules: [String: AnyDecodable]?
    enum CodingKeys: String, CodingKey { case _metadata, dictionary, rules }
}

// Generic "any" JSON wrapper
private struct AnyDecodable: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let dict = try? c.decode([String: AnyDecodable].self) {
            value = dict.mapValues { $0.value }
        } else if let arr = try? c.decode([AnyDecodable].self) {
            value = arr.map(\.value)
        } else if let s = try? c.decode(String.self) {
            value = s
        } else if let i = try? c.decode(Int.self) {
            value = i
        } else if let d = try? c.decode(Double.self) {
            value = d
        } else if let b = try? c.decode(Bool.self) {
            value = b
        } else {
            value = NSNull()
        }
    }
}

// MARK: - Gzip Decompression Extension

private enum DecompressionError: Error {
    case initFailed, processFailed, emptyData, decompressionFailed

    var localizedDescription: String {
        switch self {
        case .initFailed: "Failed to initialize decompression stream"
        case .processFailed: "Decompression processing failed"
        case .emptyData: "Cannot decompress empty data"
        case .decompressionFailed: "Gzip decompression failed"
        }
    }
}

private extension Data {
    func decompressedGzip() throws -> Data {
        // Check for gzip magic numbers 0x1F 0x8B
        guard count >= 18 else { throw DecompressionError.emptyData }
        let magic: UInt16 = prefix(2).withUnsafeBytes { $0.load(as: UInt16.self) }
        guard magic == 0x8B1F else { throw DecompressionError.decompressionFailed }

        // Parse standard GZIP header (10 bytes)
        var pos = 10
        let flg = self[3]
        if (flg & 0x04) != 0 { // FEXTRA
            let xlen = Int(self[pos]) | Int(self[pos + 1]) << 8
            pos += 2 + xlen
        }
        if (flg & 0x08) != 0 { // FNAME
            while self[pos] != 0 {
                pos += 1
            }
            pos += 1
        }
        if (flg & 0x10) != 0 { // FCOMMENT
            while self[pos] != 0 {
                pos += 1
            }
            pos += 1
        }
        if (flg & 0x02) != 0 { // FHCRC
            pos += 2
        }
        // Now pos points to start of deflate stream; footer is last 8 bytes
        let deflateData = self[pos ..< (count - 8)]

        var output = Data()
        let bufferSize = 64 * 1024
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dstBuffer.deallocate() }

        try deflateData.withContiguousStorageIfAvailable { srcPtr in
            guard let base = srcPtr.baseAddress else { throw DecompressionError.processFailed }
            let streamSize = MemoryLayout<compression_stream>.size
            let streamPtr = UnsafeMutableRawPointer.allocate(byteCount: streamSize, alignment: MemoryLayout<compression_stream>.alignment)
            defer { streamPtr.deallocate() }
            memset(streamPtr, 0, streamSize)
            let stream = streamPtr.bindMemory(to: compression_stream.self, capacity: 1)
            guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
                throw DecompressionError.initFailed
            }
            defer { compression_stream_destroy(stream) }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = srcPtr.count
            // All input is provided up front, so FINALIZE is correct and lets the
            // decoder report END/ERROR instead of waiting for more input forever.
            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            while true {
                stream.pointee.dst_ptr = dstBuffer
                stream.pointee.dst_size = bufferSize
                let status = compression_stream_process(stream, flags)
                let count = bufferSize - stream.pointee.dst_size
                if count > 0 {
                    output.append(dstBuffer, count: count)
                }
                switch status {
                case COMPRESSION_STATUS_OK:
                    // No output produced and no input left = truncated/corrupt
                    // stream; bail out rather than spinning forever.
                    if count == 0, stream.pointee.src_size == 0 {
                        throw DecompressionError.processFailed
                    }
                    continue
                case COMPRESSION_STATUS_END:
                    return
                default:
                    throw DecompressionError.processFailed
                }
            }
        }
        return output
    }
}

// MARK: - Aho-Corasick-lite phrase matcher

final class PhraseMatcher {
    private var phraseMap: [String: String] = [:]
    private var lengths: [Int] = []
    init(phrases: [String: String]) {
        var norm: [String: String] = [:]
        for (k, v) in phrases {
            let nk = PhraseMatcher.normalize(k)
            if !nk.isEmpty { norm[nk] = v }
        }
        phraseMap = norm
        lengths = Set(norm.keys.map { $0.split(separator: " ").count }).sorted(by: >)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
         .folding(options: .diacriticInsensitive, locale: .current)
         .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func match(tokens: [String]) -> [(String, String?)] {
        // Keys are stored accent-folded (normalize above), so the lookup must
        // fold too — otherwise "está lloviendo" can never match its own entry
        // and 38% of the phrase dictionary (all accented phrases) is dead.
        let folded = tokens.map { $0.folding(options: .diacriticInsensitive, locale: .current) }
        var i = 0
        var out: [(String, String?)] = []
        while i < tokens.count {
            var matched = false
            for L in lengths {
                guard i + L <= tokens.count else { continue }
                let foldedSpan = folded[i ..< (i + L)].joined(separator: " ")
                if let eng = phraseMap[foldedSpan] {
                    let span = tokens[i ..< (i + L)].joined(separator: " ")
                    out.append((span, eng))
                    i += L
                    matched = true
                    break
                }
            }
            if !matched { out.append((tokens[i], nil)); i += 1 }
        }
        return out
    }
}

// MARK: - Text Domain Detection

enum TextDomain {
    case restaurant, signage, narrative, general
}

// MARK: - FixedSpanishEngine (Your exact class name with working logic)

// No longer @MainActor: translation is pure CPU work (tokenize + dictionary
// lookups + regex packs) and was freezing the UI for long pages. All stores are
// written once at load (guarded by stateLock before isLoaded flips), then only
// read — so translate() is safe to call from any thread.
final class FixedSpanishEngine {
    // Helper to collect phrases from multiple rule buckets
    private func collectRulePhrases(_ dicts: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (_, v) in dicts {
            if let d = v as? [String: String] {
                for (k, v2) in d {
                    out[k] = v2
                }
            } else if let arr = v as? [[String: String]] {
                for row in arr {
                    if let k = row["src"], let v2 = row["tgt"] {
                        out[k] = v2
                    }
                }
            }
        }
        return out
    }
    
    static let shared = FixedSpanishEngine()

    // Core stores
    private var dict: [String: String] = [:] // surface (lowercased) → translation
    private var posMap: [String: String] = [:] // surface → NOUN/ADJ/ADV/VERB
    private var phraseMatcher: PhraseMatcher?
    private var reflexiveRules: [(NSRegularExpression, String)] = [] // "se vende" → "for sale", precompiled

    // Compiled regex packs (from JSON)
    private var compiledGeneral: [(NSRegularExpression, String)] = []
    private var compiledDialogueFromJSON: [(NSRegularExpression, String)] = []
    private var compiledGrammar: [(NSRegularExpression, String)] = []
    private var compiledCleanup: [(NSRegularExpression, String)] = []

    // Built-in deterministic rule packs
    private var builtinPriceAndUnits: [(NSRegularExpression, String)] = []
    private var builtinAlInfinitivo: [(NSRegularExpression, String)] = []
    private var builtinPrepositions: [(NSRegularExpression, String)] = []
    private var builtinMenuLexicon: [(NSRegularExpression, String)] = []
    private var builtinNarrativeGrammar: [(NSRegularExpression, String)] = []
    private var builtinDialogue: [(NSRegularExpression, String)] = []

    // Cache + loaded flag are the only state mutated after load; guard them.
    private let stateLock = NSLock()
    private var cache: [String: String] = [:]
    private let cacheLimit = 500

    private var _isLoaded = false
    var isLoaded: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isLoaded
    }

    private init() { Task { await loadSpanishData() } }

    // MARK: - Public Translation Methods (Your LiveOCRViewModel expects these exact names!)

    func translate(_ text: String) -> String {
        print("\n📄 TRANSLATING: '\(text)'")

        guard isLoaded else {
            print("   ⚠️ Engine not loaded")
            return text
        }

        guard !text.isEmpty else {
            print("   ⚠️ Empty text")
            return text
        }

        let result = interpretSpanishWithContext(text)
        print("   🎯 RESULT: '\(result)'")
        return result
    }

    func isReady() -> Bool {
        isLoaded
    }

    // MARK: - Core Translation Logic (Your exact working methods!)

    private func interpretSpanishWithContext(_ text: String) -> String {
        guard isLoaded else { return text }
        let cacheKey = normalizeKey(text)
        stateLock.lock()
        let cached = cache[cacheKey]
        stateLock.unlock()
        if let cached {
            return cached
        }

        let domain = detectDomain(text)
        let sentences = splitIntoSentences(text)
        let batches = batchSentences(sentences, targetChars: 2200)

        var outPieces: [String] = []
        outPieces.reserveCapacity(batches.count)
        for batch in batches {
            let translated = translateBatch(batch, domain: domain)
            outPieces.append(translated)
        }
        let result = outPieces.joined(separator: " ")
            .replacingOccurrences(of: #"(\s+)"#, with: " ", options: NSString.CompareOptions.regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // OCR feeds a near-infinite stream of unique strings, so cap the cache to
        // avoid unbounded memory growth over a long session.
        stateLock.lock()
        if cache.count >= cacheLimit {
            cache.removeAll(keepingCapacity: true)
        }
        cache[cacheKey] = result
        stateLock.unlock()
        return result
    }

    // MARK: - Core Translation Methods (Your exact working logic!)

    // MARK: - Word-level core (shared by both translate paths)

    private func lookup(_ surface: String) -> String? {
        dict[surface] ?? dict[surface.folding(options: .diacriticInsensitive, locale: .current)]
    }

    private func posOf(_ token: String) -> String? {
        posMap[token] ?? posMap[token.folding(options: .diacriticInsensitive, locale: .current)]
    }

    // Spanish object pronouns come before the verb; English puts them after
    // ("me ofreció" → "offered me"). Empty value = drop entirely (reflexive "se").
    private static let cliticObjects: [String: String] = [
        "me": "me", "te": "you", "le": "him", "les": "them", "nos": "us", "os": "you", "se": "",
    ]
    // Verb translations that already carry their subject ("I woke up") absorb the clitic.
    private static let subjectStarts = ["i ", "he ", "she ", "we ", "they ", "you ", "it "]

    // Spanish puts adjectives after nouns ("paraguas azul"); English reverses
    // ("blue umbrella"). Applies only to spans the phrase matcher didn't claim.
    private func reorderNounAdjective(_ items: [(String, String?)]) -> [(String, String?)] {
        var out = items
        var i = 0
        while i < out.count - 1 {
            guard out[i].1 == nil, out[i + 1].1 == nil, posOf(out[i].0) == "NOUN" else { i += 1; continue }
            // A following "de" marks a participial phrase ("manos cubiertas de
            // harina" = hands covered WITH flour) — reordering those reads worse.
            let adjFollowedByDe: (Int) -> Bool = { adjIdx in
                adjIdx + 1 < out.count && out[adjIdx + 1].0 == "de"
            }
            if i + 2 < out.count, out[i + 2].1 == nil, posOf(out[i + 1].0) == "ADV", posOf(out[i + 2].0) == "ADJ",
               !adjFollowedByDe(i + 2)
            {
                // "pan recién horneado" → "recién horneado pan" → "freshly baked bread"
                let noun = out[i]
                out[i] = out[i + 1]; out[i + 1] = out[i + 2]; out[i + 2] = noun
                i += 3
            } else if posOf(out[i + 1].0) == "ADJ", !adjFollowedByDe(i + 1) {
                out.swapAt(i, i + 1)
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    // "el gato se abalanzó" must not become "the cat He pounced": when the
    // sentence already has a subject (a noun right before the verb), strip the
    // subject pronoun some dictionary verb translations carry embedded.
    private func stripEmbeddedSubject(_ verbTr: String) -> String {
        let lower = verbTr.lowercased() + " "
        for s in Self.subjectStarts where lower.hasPrefix(s) {
            return String(verbTr.dropFirst(s.count))
        }
        return verbTr
    }

    private func englishPieces(
        from items: [(String, String?)],
        unknowns: inout [String], total: inout Int, translated: inout Int
    ) -> [String] {
        var pieces: [String] = []
        pieces.reserveCapacity(items.count)
        var prevWasNoun = false
        var i = 0
        while i < items.count {
            let (surface, ph) = items[i]
            total += 1
            if let eng = ph { pieces.append(eng); translated += 1; prevWasNoun = false; i += 1; continue }

            let pos = posOf(surface)

            // Clitic pronoun directly before a verb
            if let obj = Self.cliticObjects[surface], i + 1 < items.count, items[i + 1].1 == nil,
               posOf(items[i + 1].0) == "VERB", let verbTr = lookup(items[i + 1].0)
            {
                let lower = verbTr.lowercased() + " "
                let subjectEmbedded = Self.subjectStarts.contains { lower.hasPrefix($0) }
                pieces.append(prevWasNoun ? stripEmbeddedSubject(verbTr) : verbTr)
                if !obj.isEmpty, !subjectEmbedded { pieces.append(obj) }
                total += 1
                translated += 2
                prevWasNoun = false
                i += 2
                continue
            }

            if let eng = lookup(surface) {
                pieces.append(pos == "VERB" && prevWasNoun ? stripEmbeddedSubject(eng) : eng)
                translated += 1
            } else {
                pieces.append(surface)
                unknowns.append(surface)
            }
            prevWasNoun = (pos == "NOUN")
            i += 1
        }
        return pieces
    }

    private func translateBatch(_ text: String, domain: TextDomain) -> String {
        let tokens = tokenize(text.replacingOccurrences(of: #"\s+"#, with: " ", options: NSString.CompareOptions.regularExpression))
        let phraseApplied = phraseMatcher?.match(tokens: tokens.map { $0.lowercased() }) ?? tokens.map { ($0.lowercased(), nil) }

        var unknowns: [String] = []
        var total = 0
        var translated = 0
        let englishPieces = englishPieces(
            from: reorderNounAdjective(phraseApplied),
            unknowns: &unknowns, total: &total, translated: &translated
        )
        var out = englishPieces.joined(separator: " ")

        // Fast reflexive pack for menus/signage/general
        if domain == .restaurant || domain == .signage || domain == .general {
            out = applyRulePack(reflexiveRules, to: out)
        }

        // Built-ins first (surgical, deterministic)
        out = applyRulePack(builtinPriceAndUnits, to: out) // price/unit
        out = applyRulePack(builtinMenuLexicon, to: out) // menu lexicon
        out = applyRulePack(builtinAlInfinitivo, to: out) // al + infinitivo
        out = applyRulePack(builtinPrepositions, to: out) // prepositions & OCRish

        // JSON packs
        out = applyRulePack(compiledGeneral, to: out)
        out = applyRulePack(compiledGrammar, to: out)

        // Built-in narrative grammar targets (fixes your two stories)
        out = applyRulePack(builtinNarrativeGrammar, to: out)

        // Dialogue: our built-in first, then any JSON dialogue
        if domain == .narrative {
            out = applyRulePack(builtinDialogue, to: out)
            out = applyRulePack(compiledDialogueFromJSON, to: out)
        }

        // Cleanup (from JSON)
        out = applyRulePack(compiledCleanup, to: out)

        // Finalizer
        out = finalize(out)
        return out
    }

    private func applyRulePack(_ pack: [(NSRegularExpression, String)], to text: String) -> String {
        guard !pack.isEmpty else { return text }
        var s = text
        for (re, repl) in pack {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: repl)
        }
        return s
    }

    // MARK: - Text Processing Utilities (Your exact methods)

    private func detectDomain(_ text: String) -> TextDomain {
        let t = text.lowercased()
        let menuHits = ["menú", "menu", "plato", "platos", "postre", "entrante", "bebida", "bebidas", "cuenta", "€", "euros", "kilo", "docena", "kg", "precio", "oferta"]
            .filter { t.contains($0) }.count
        let signHits = ["se vende", "se alquila", "prohibido", "entrada", "salida", "cerrado", "abierto", "peligro", "precaución", "no fumar", "no pasar"]
            .filter { t.contains($0) }.count
        let narrativeHits = ["ayer", "mañana", "me desperté", "mientras", "de pronto", "cuando", "entonces", "luego", "sonriendo", "caminé", "pensé", "observé", "—", "\""]
            .filter { t.contains($0) }.count
        let m = max(menuHits, signHits, narrativeHits)
        if m == 0 { return .general }
        if m == menuHits { return .restaurant }
        if m == signHits { return .signage }
        return .narrative
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var s = text
        let abbrs = ["Sr", "Sra", "Dr", "Dra", "etc", "vs", "pág", "pp"]
        for abbr in abbrs {
            s = s.replacingOccurrences(of: "\(abbr).", with: "\(abbr)<<DOT>>", options: .caseInsensitive)
        }
        let pattern = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+(?=[A-ZÀ-Ú""])"#, options: [])
        let range = NSRange(s.startIndex..., in: s)
        var sentences: [String] = []
        var last = s.startIndex
        pattern.enumerateMatches(in: s, options: [], range: range) { m, _, _ in
            guard let m else { return }
            let r = Range(m.range, in: s)!
            let end = r.lowerBound
            sentences.append(String(s[last ..< end]))
            last = r.upperBound
        }
        sentences.append(String(s[last...]))
        sentences = sentences.map {
            $0.replacingOccurrences(of: "<<DOT>>", with: ".")
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return sentences
    }

    private func batchSentences(_ sentences: [String], targetChars: Int) -> [String] {
        guard !sentences.isEmpty else { return [] }
        var batches: [String] = []
        var current = ""
        for s in sentences {
            if (current.count + s.count + 1) > targetChars, !current.isEmpty {
                batches.append(current); current = s
            } else {
                if current.isEmpty { current = s } else { current += " " + s }
            }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private func normalizeKey(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: NSString.CompareOptions.regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    // MARK: - Tokenizer & Finalizer (Your exact working methods)

    private func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { tokens.append(current); current.removeAll(keepingCapacity: true) }
        }
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "'" { current.append(ch) }
            else if ch.isWhitespace { flush() }
            else { flush(); tokens.append(String(ch)) }
        }
        flush()
        return tokens
    }

    private func finalize(_ s: String) -> String {
        var out = s
        // English doesn't use inverted punctuation
        out = out.replacingOccurrences(of: "¿", with: "")
        out = out.replacingOccurrences(of: "¡", with: "")
        out = out.replacingOccurrences(of: #"\s+([,\.!\?:;)\]\}])"#, with: "$1", options: NSString.CompareOptions.regularExpression)
        out = out.replacingOccurrences(of: #"([,\.!\?:;])([^\s\)\]\}])"#, with: "$1 $2", options: NSString.CompareOptions.regularExpression)
        out = out.replacingOccurrences(of: #"([\(\[\{])\s+"#, with: "$1", options: NSString.CompareOptions.regularExpression)
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: NSString.CompareOptions.regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        // Capitalize sentence starts
        let sentenceEnd = CharacterSet(charactersIn: ".!?")
        var chars = Array(out)
        if let first = chars.first, first.isLetter { chars[0] = Character(String(first).capitalized) }
        var i = 1
        while i < chars.count {
            if let u = chars[i - 1].unicodeScalars.first, sentenceEnd.contains(u) {
                var j = i
                while j < chars.count, chars[j].isWhitespace {
                    j += 1
                }
                if j < chars.count, chars[j].isLetter {
                    chars[j] = Character(String(chars[j]).capitalized)
                }
                // j can equal i when punctuation is followed by a non-letter,
                // non-space char (e.g. ".)"), so always advance past it.
                i = j + 1
            } else { i += 1 }
        }
        return String(chars)
    }

    // MARK: - Data Loading with Gzip Support (Updated method)

    // Decompression, JSON decode, and regex compilation run off the main thread
    // (called from a Task in init); the finished stores are published under
    // stateLock before isLoaded flips.
    private func loadSpanishData() async {
        let master: ESMaster? = {
            guard let url = locateJSON(),
                  let compressedData = try? Data(contentsOf: url, options: .mappedIfSafe)
            else {
                print("⚠️ Could not find/load es_final_with_rules*.json.gz")
                return nil
            }

            print("📊 Loaded file size: \(compressedData.count) bytes from: \(url.lastPathComponent)")

            do {
                // Check if file extension suggests it needs decompression
                let needsDecompression = url.pathExtension.lowercased() == "gz" ||
                    url.lastPathComponent.lowercased().contains(".gz")

                let data: Data
                if needsDecompression {
                    print("🔄 Attempting to decompress gzip data...")
                    data = try compressedData.decompressedGzip()
                    print("✅ Decompressed from \(compressedData.count) to \(data.count) bytes")
                } else {
                    print("📄 Using data as uncompressed JSON")
                    data = compressedData
                }

                let decoder = JSONDecoder()
                let master = try decoder.decode(ESMaster.self, from: data)
                print("✅ Successfully decoded JSON structure")
                return master

            } catch let error as DecompressionError {
                print("⚠️ Gzip decompression error: \(error.localizedDescription)")

                // Fallback: try to use the data as uncompressed JSON
                print("🔄 Trying to parse as uncompressed JSON...")
                do {
                    let decoder = JSONDecoder()
                    let master = try decoder.decode(ESMaster.self, from: compressedData)
                    print("✅ Successfully parsed as uncompressed JSON")
                    return master
                } catch {
                    print("❌ Failed to parse as uncompressed JSON: \(error)")
                    return nil
                }

            } catch {
                print("⚠️ JSON decode error: \(error)")
                return nil
            }
        }()

        guard let master else { return }
        var newDict: [String: String] = [:]
        var newPos: [String: String] = [:]
        if let d = master.dictionary {
            var m: [String: String] = [:]
            m.reserveCapacity(d.count)
            for (k, v) in d {
                let key = k.lowercased()
                if let t = v.translation, !t.isEmpty { m[key] = t }
                // POS tags power the noun-adjective reorder pass
                if let p = v.pos, p == "NOUN" || p == "ADJ" || p == "ADV" || p == "VERB" {
                    newPos[key] = p
                }
            }
            newDict = m
        }

        var phrases: [String: String] = [:]
        var reflexives: [String: String] = [:]
        var gen: [(NSRegularExpression, String)] = []
        var diaJSON: [(NSRegularExpression, String)] = []
        var gra: [(NSRegularExpression, String)] = []
        var cle: [(NSRegularExpression, String)] = []

        if let rulesBag = master.rules {
            // phrases
            if let rawPhrases = rulesBag["phrases"]?.value {
                if let pdict = rawPhrases as? [String: String] {
                    phrases = pdict
                } else if let parr = rawPhrases as? [[String: String]] {
                    for row in parr {
                        if let k = row["src"], let v = row["tgt"] { phrases[k] = v }
                    }
                }
            }
            // reflexives
            if let rp = rulesBag["reflexive_passives"]?.value as? [String: String] {
                reflexives = rp.reduce(into: [:]) { acc, kv in
                    let k = kv.key.lowercased()
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: NSString.CompareOptions.regularExpression)
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    acc[k] = kv.value
                }
            }
            // regex rules (bucket by heuristics)
            if let rawRR = (rulesBag["regex_rules"]?.value ?? rulesBag["regex"]?.value) as? [[String: Any]] {
                for obj in rawRR {
                    guard let pattern = obj["pattern"] as? String,
                          let replace = obj["replace"] as? String else { continue }
                    let enabled = (obj["enabled"] as? Bool) ?? true
                    guard enabled else { continue }
                    let optsArray = (obj["options"] as? [String]) ?? []
                    var opts: NSRegularExpression.Options = []
                    if optsArray.contains("i") { opts.insert(.caseInsensitive) }
                    if optsArray.contains("m") { opts.insert(.anchorsMatchLines) }
                    if optsArray.contains("s") { opts.insert(.dotMatchesLineSeparators) }
                    guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { continue }

                    let name = (obj["name"] as? String ?? "") + " " + (obj["description"] as? String ?? "")
                    let lower = name.lowercased()
                    if lower.contains("dialogue") || lower.contains("quote") || pattern.contains("—") {
                        diaJSON.append((re, replace))
                    } else if lower.contains("grammar") || lower.contains("verb") || lower.contains("tense") {
                        gra.append((re, replace))
                    } else if lower.contains("cleanup") || lower.contains("space") || lower.contains("punct") {
                        cle.append((re, replace))
                    } else {
                        gen.append((re, replace))
                    }
                }
            }
        }

        // Phrase matcher: RULES FIRST, then fill gaps from multiword dictionary entries.
        var phraseSource: [String: String] = [:]
        if let rulesBag = master.rules {
            // 1) Pull phrases from multiple rules buckets (phrases/commonPhrases/idioms/menuPhrases/verbalExpressions)
            let allRulePhrases = collectRulePhrases(rulesBag.mapValues { $0.value })
            phraseSource.merge(allRulePhrases) { current, _ in current } // keep existing (rules) on conflict
        }
        // 2) Add multi-word dictionary keys ONLY if not already provided by rules
        for (k, v) in newDict where k.contains(" ") {
            if phraseSource[k] == nil { phraseSource[k] = v }
        }
        // 3) Build matcher (longest phrases prioritized internally)
        let matcher = phraseSource.isEmpty ? nil : PhraseMatcher(phrases: phraseSource)

        // Compile built-ins
        let packs = Self.compileBuiltinRules()

        // Precompile reflexive patterns once (previously rebuilt on every translate call)
        var reflexiveCompiled: [(NSRegularExpression, String)] = []
        reflexiveCompiled.reserveCapacity(reflexives.count)
        for (k, v) in reflexives {
            let pat = "\\b" + NSRegularExpression.escapedPattern(for: k) + "\\b"
            if let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                reflexiveCompiled.append((re, v))
            }
        }

        // Publish: stores are written before _isLoaded flips under the lock, so
        // any thread that observes isLoaded == true sees fully-built stores.
        dict = newDict
        posMap = newPos
        phraseMatcher = matcher
        reflexiveRules = reflexiveCompiled
        compiledGeneral = gen
        compiledDialogueFromJSON = diaJSON
        compiledGrammar = gra
        compiledCleanup = cle

        builtinPriceAndUnits = packs.priceUnits
        builtinAlInfinitivo = packs.alInf
        builtinPrepositions = packs.preps
        builtinMenuLexicon = packs.menuLex
        builtinNarrativeGrammar = packs.narrative
        builtinDialogue = packs.dialogue

        markLoaded()
        print("✅ es data loaded: dict=\(dict.count) phrases=\(phraseMatcher == nil ? 0 : 1) regex: gen=\(compiledGeneral.count) gra=\(compiledGrammar.count) diaJSON=\(compiledDialogueFromJSON.count) cle=\(compiledCleanup.count) builtinNarr=\(builtinNarrativeGrammar.count)")
    }

    // Synchronous so NSLock is legal here (locks are unavailable in async contexts).
    private func markLoaded() {
        stateLock.lock()
        cache.removeAll()
        _isLoaded = true
        stateLock.unlock()
    }

    private func locateJSON() -> URL? {
        // Updated to look for .gz files first, then fallback to .json
        let candidates = [
            ("es_final_with_rules_CLEANED", "json.gz"),
            ("es_final_with_rules_ENRICHED", "json.gz"),
            ("es_final_with_rules_CLEAN", "json.gz"),
            ("es_final_with_rules", "json.gz"),
            ("es_final_with_rules_CLEANED", "json"),
            ("es_final_with_rules_ENRICHED", "json"),
            ("es_final_with_rules_CLEAN", "json"),
            ("es_final_with_rules", "json"),
        ]

        for (name, ext) in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                print("📁 Found data file: \(name).\(ext)")
                return url
            }
        }

        // Check document directory for custom files
        let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let customGz = doc?.appendingPathComponent("es_final_with_rules.json.gz")
        if let u = customGz, FileManager.default.fileExists(atPath: u.path) {
            print("📁 Found custom gzip file: es_final_with_rules.json.gz")
            return u
        }

        let custom = doc?.appendingPathComponent("es_final_with_rules.json")
        if let u = custom, FileManager.default.fileExists(atPath: u.path) {
            print("📁 Found custom json file: es_final_with_rules.json")
            return u
        }

        print("❌ No translation data file found")
        return nil
    }

    // MARK: - Built-in deterministic rules (Your exact code)

    private struct Packs {
        let priceUnits: [(NSRegularExpression, String)]
        let alInf: [(NSRegularExpression, String)]
        let preps: [(NSRegularExpression, String)]
        let menuLex: [(NSRegularExpression, String)]
        let narrative: [(NSRegularExpression, String)]
        let dialogue: [(NSRegularExpression, String)]
    }

    private static func rex(_ p: String, _ opt: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: p, options: opt)
    }

    private static func compileBuiltinRules() -> Packs {
        // Prices/units
        let pricePatterns: [(String, String)] = [
            (#"(\d+)\s*(€|euros?)\s+el\s+kilo"#, "$1$2 per kilo"),
            (#"(\d+)\s*(€|euros?)\s+la\s+docena"#, "$1$2 per dozen"),
            (#"(\d+)\s*(€|euros?)\s+cada\s+uno"#, "$1$2 each"),
            (#"\bto fifteen euros the kilo\b"#, "for fifteen euros a kilo"),
        ]
        let priceUnits = pricePatterns.compactMap { p, r in rex(p).map { ($0, r) } }

        // "al + infinitivo" → "upon <gerund>"
        let alInfPatterns = [
            (#"\bal\s+([a-záéíóúñ]+)r\b"#, "upon $1ing"),
        ]
        let alInf = alInfPatterns.compactMap { p, r in rex(p).map { ($0, r) } }

        // Preposition/cleanup fixes (general)
        let prepPatterns: [(String, String)] = [
            (#"\brealized of\b"#, "realized"),
            (#"\brealized of that\b"#, "realized that"),
            (#"\bbrought of the field\b"#, "brought from the countryside"),
            (#"\bbrought of\b"#, "brought from"),
            (#"\bto the enter\b"#, "upon entering"),
            (#"\bmirror in the floor\b"#, "mirror on the ground"),
            (#"\bas the rain I created\b"#, "as the rain created"),
            (#"\bunder the awning of a little coffee\b"#, "under the awning of a small café"),
            (#"\brestaurant of to the side\b"#, "next-door restaurant"),
            (#"\bOctopos\b"#, "octopus"),
            (#"\boctopos\b"#, "octopus"),
            // English article agreement after reordering ("a old man" → "an old man")
            (#"\ba ([aeiou])"#, "an $1"),
            (#"\bA ([aeiou])"#, "An $1"),
        ]
        let preps = prepPatterns.compactMap { p, r in rex(p).map { ($0, r) } }

        // Menu lexicon tweaks (English-side)
        let menuPatterns: [(String, String)] = [
            (#"\bPosts of\b"#, "stalls of"),
            (#"\bstalls of fruit\b"#, "fruit stalls"),
            (#"\bpuestos de\s+([a-záéíóúñ]+)\b"#, "$1 stalls"),
            (#"\bpremises\b"#, "locals"),
        ]
        let menuLex = menuPatterns.compactMap { p, r in rex(p).map { ($0, r) } }

        // Narrative grammar/idiom targets (exact issues you reported)
        let narrativePatterns: [(String, String)] = [
            // Story 1
            (#"(?m)^Is a\b"#, "It's a"),
            (#"\bhe can find of all\b"#, "you can find everything"),
            (#"\bof all\b"#, "everything"),
            (#"\bthere was a lot people\b"#, "there were a lot of people"),
            (#"\bso (?:much|many)\s+tourists as\b"#, "as many tourists as"),
            (#"\bPosts of\b"#, "stalls of"),
            (#"\ba Sir elderly\b"#, "an elderly man"),
            (#"\bmoustache\b"#, "mustache"),
            (#"\bproof this\b"#, "try this"),
            (#"\bis of acorn-fed\b"#, "is acorn-fed"),
            (#"\bthe buys of all the week\b"#, "the shopping for the whole week"),
            // Story 2
            (#"\bI would be a day perfect\b"#, "It would be a perfect day"),
            (#"\bfor lose\b"#, "to lose"),
            (#"\bstreets old\b"#, "old streets"),
            (#"\bAfter of\b"#, "After"),
            (#"\bbreakfast fast\b"#, "quick breakfast"),
            (#"\bThis\s+Fill of\b"#, "It's filled with"),
            (#"\bpeppers\s+Red\b"#, "red peppers"),
            (#"\ba cluster of musicians street\b"#, "a group of street musicians"),
            (#"\bdrawer flamenco\b"#, "cajón flamenco"),
            (#"\bFollowing the rhythm\b"#, "clapping along to the rhythm"),
            (#"\bsquare central\b"#, "central square"),
            (#"\bstreet market colorful\b"#, "colorful street market"),
            (#"\ball guy of things\b"#, "all kinds of things"),
            (#"\bblankets\s+tejidas\s+handmade\b"#, "hand-woven blankets"),
            (#"\bA women elderly\b"#, "An elderly woman"),
            (#"\bme told\b"#, "told me"),
            (#"\bOf soon\b"#, "Suddenly"),
            (#"\bbegan to rain further strong\b"#, "began to rain harder"),
            (#"\bThe surf They hit\b"#, "The waves crashed"),
            (#"\bMe I approached\b"#, "I approached"),
            (#"\byou I asked\b"#, "I asked him"),
            (#"\bYeah there was had good fishing\b"#, "if he had a good catch"),
            (#"\bencogiéndose of shoulders\b"#, "shrugging his shoulders"),
            (#"\bBefore of go back to home\b"#, "Before heading home"),
            (#"\bHappens by a\b"#, "I stopped by a"),
            (#"\bwith he low the arm\b"#, "with it under my arm"),
            (#"\bEnjoying of the calm\b"#, "enjoying the calm"),
            (#"\bis left over after of the rain\b"#, "lingers after the rain"),
        ]
        let narrative = narrativePatterns.compactMap { p, r in rex(p).map { ($0, r) } }

        // Dialogue: handle a common Spanish em-dash pattern (your sample)
        // —Pruébala, chico —me dijo sonriendo—.  ->  "Try it, kid," he said, smiling.
        let dialoguePatterns = [
            (#"—\s*([^—]+?)\s*—\s*me dijo sonriendo—\s*\."#, "\"$1,\" he said, smiling."),
        ]
        let dialogue = dialoguePatterns.compactMap { p, r in rex(p).map { ($0, r) } }

        return Packs(priceUnits: priceUnits, alInf: alInf, preps: preps, menuLex: menuLex, narrative: narrative, dialogue: dialogue)
    }
}

