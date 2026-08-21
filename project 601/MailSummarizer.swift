import Foundation

/// Turns the raw text the OCR pulled off a letter into the one sentence a
/// sighted person would get from a two-second glance: who sent it, what it is,
/// what's owed, when it's due.
///
/// This is deliberately PLAIN CODE — no model, no network, nothing to download.
/// A letter is mostly boilerplate, and the four facts that matter sit in
/// predictable places, so pattern matching gets them on any phone the app already
/// runs on (iOS 16 up). The on-device LLM tier is layered on top later for the
/// phones that have one; it is never required for this to work.
enum MailSummarizer {

    enum Kind {
        case bill
        case advertisement
        case appointment
        case statement
        case official
        case benefits
        case refund
        case delivery
        case unknown

        /// Spoken name. Deliberately blunt — "Advertisement" is the word that
        /// saves someone the trouble.
        var spoken: String {
            switch self {
            case .bill: "Bill"
            case .advertisement: "Advertisement"
            case .appointment: "Appointment"
            case .statement: "Statement"
            case .official: "Official notice"
            case .benefits: "Explanation of benefits"
            case .refund: "Refund"
            case .delivery: "Delivery notice"
            case .unknown: "Letter"
            }
        }
    }

    struct Summary {
        var sender: String?
        var kind: Kind
        var amount: String?
        var dueDate: String?
        /// What the app actually says out loud.
        var spoken: String
    }

    // MARK: - Entry point

    static func summarize(_ raw: String) -> Summary {
        let lines = stitch(raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        let flat = lines.joined(separator: "\n")
        let lower = flat.lowercased()

        let kind = classify(lower)
        let sender = findSender(lines)
        // An ad's "$500 value!" is not money you owe — never read it as one.
        let amount = kind == .advertisement ? nil : findAmount(lines, kind: kind)
        let due = kind == .advertisement ? nil : findDueDate(flat, lower: lower)

        return Summary(
            sender: sender, kind: kind, amount: amount, dueDate: due,
            spoken: speak(sender: sender, kind: kind, amount: amount, due: due, lines: lines)
        )
    }

    // MARK: - Prose

    /// A bill has four facts in known places. A letter or an article has none of
    /// that — there is no pattern to match, so pattern matching cannot summarize
    /// it and pretending otherwise would invent things that aren't on the page.
    /// What plain code CAN honestly give is a preview: how long it is, and how it
    /// opens. Real summarizing arrives with the on-device model on newer phones.
    private static func prosePreview(_ lines: [String], sender: String?) -> String? {
        // Drop the letterhead, the address block and the postal furniture — the
        // body is what someone wants previewed.
        let body = lines.filter { line in
            let lower = line.lowercased()
            if looksLikeAddress(line) { return false }
            if junkLinePatterns.contains(where: { containsPhrase(lower, $0) }) { return false }
            if let sender, line.localizedCaseInsensitiveContains(sender) { return false }
            return line.filter { $0.isLetter }.count >= 12
        }
        guard !body.isEmpty else { return nil }

        let text = body.joined(separator: " ")
        let words = text.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.count
        guard words >= 25 else { return nil }

        // Read aloud runs about 150 words a minute, so this is the honest answer
        // to "how long am I committing to?"
        let minutes = max(1, Int((Double(words) / 150.0).rounded()))
        let length = "About \(words) words, roughly \(minutes) minute\(minutes == 1 ? "" : "s") to read"

        var opening = firstSentences(text, max: 2)
        if opening.count > 240 {
            opening = String(opening.prefix(240)).trimmingCharacters(in: .whitespaces) + "…"
        }

        var parts: [String] = []
        if let sender { parts.append(sender) }
        parts.append(length)
        if !opening.isEmpty {
            // The sentence already ends in a period; adding ours makes the voice
            // pause twice.
            let trimmed = opening.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            parts.append("It begins. \(trimmed)")
        }
        parts.append("Tap the text to hear all of it")
        return parts.joined(separator: ". ") + "."
    }

    private static func firstSentences(_ text: String, max count: Int) -> String {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                // Skip the salutation — "Dear Matthew," is not the point of a letter.
                if sentence.filter({ $0.isLetter }).count >= 12,
                   !sentence.lowercased().hasPrefix("dear ") {
                    out.append(sentence)
                }
                current = ""
                if out.count >= count { break }
            }
        }
        if out.isEmpty {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if trimmed.filter({ $0.isLetter }).count >= 12 { out.append(trimmed) }
        }
        return out.joined(separator: " ")
    }

    /// Big type gets split by the recognizer: the dollar sign lands on its own
    /// line, or a label ends up alone above its number. Rejoin those before
    /// anything tries to read meaning out of them.
    private static func stitch(_ lines: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let next = i + 1 < lines.count ? lines[i + 1] : nil
            if line == "$" || line == "$ ", let next {
                out.append("$" + next)
                i += 2
                continue
            }
            // A bare label with its figure orphaned on the following line.
            if let next,
               amountCues.contains(where: { line.lowercased().contains($0) }),
               currency(in: line) == nil, bareAmount(in: line) == nil,
               currency(in: next) != nil || bareAmount(in: next) != nil {
                out.append(line + " " + next)
                i += 2
                continue
            }
            out.append(line)
            i += 1
        }
        return out
    }

    // MARK: - What kind of mail is this

    // Spanish terms sit alongside the English ones throughout: the app already
    // does Spanish OCR, so Spanish mail has to work or the feature is a lie for
    // half the people who'd want it most.
    private static let adPhrases = [
        "this is an advertisement", "paid advertisement", "advertisement",
        "you may qualify", "you have been pre-selected", "pre-approved",
        "act now", "limited time offer", "no purchase necessary",
        "not affiliated with any government", "offer expires", "apply today",
        "special offer", "publicidad", "esto es un anuncio", "oferta especial",
    ]
    private static let billPhrases = [
        "amount due", "total due", "payment due", "past due", "balance due",
        "please pay", "pay this amount", "invoice", "minimum payment",
        "amount enclosed", "billing period", "attempt to collect a debt",
        "factura", "cantidad a pagar", "total a pagar", "saldo vencido",
        "pago vencido", "importe a pagar",
    ]
    private static let appointmentPhrases = [
        "appointment", "you are scheduled", "please arrive", "your visit",
        "confirm your appointment", "reschedule", "cita", "su cita",
    ]
    private static let officialPhrases = [
        "summons", "jury", "court", "notice of", "hearing", "you are hereby",
        "failure to respond", "department of", "internal revenue",
        "polling place", "notification card", "citacion", "tribunal",
    ]
    private static let statementPhrases = [
        "statement", "account summary", "your balance", "transactions",
        "estado de cuenta", "resumen de cuenta",
    ]
    private static let refundPhrases = [
        "your refund", "refund check", "enclosed is your refund", "reembolso",
        "credit balance refund", "overpayment refund",
    ]
    private static let deliveryPhrases = [
        "was delivered", "delivery notice", "your package", "tracking",
        "su paquete", "entregado",
    ]

    private static func classify(_ lower: String) -> Kind {
        // Every insurance EOB prints "THIS IS NOT A BILL" — so does junk mail.
        // Check for the EOB first or a medical letter gets called advertising,
        // which is the worst possible thing this app could say.
        if lower.contains("explanation of benefits") || lower.contains("your responsibility") {
            return .benefits
        }
        // Only the explicit disclosure marks advertising on its own. "This is not
        // a bill" is NOT enough evidence by itself.
        if lower.contains("this is an advertisement") || lower.contains("paid advertisement")
            || lower.contains("esto es un anuncio") {
            return .advertisement
        }
        // Money coming TO you is the opposite of a bill and must never be read as one.
        if refundPhrases.contains(where: lower.contains) { return .refund }
        if deliveryPhrases.contains(where: lower.contains) { return .delivery }
        // A court or a tax agency writing to you outranks the fact that a dollar
        // figure appears — a summons is not a bill.
        if officialPhrases.contains(where: lower.contains) { return .official }
        if billPhrases.contains(where: lower.contains) { return .bill }
        if appointmentPhrases.contains(where: lower.contains) { return .appointment }
        if adPhrases.contains(where: lower.contains) { return .advertisement }
        if statementPhrases.contains(where: lower.contains) { return .statement }
        return .unknown
    }

    // MARK: - Who sent it

    /// Postal furniture that OCR reads first and nobody wants to hear.
    /// Matched as whole phrases at a word boundary — as a bare substring, "auto"
    /// swallowed STATE FARM MUTUAL AUTOMOBILE INSURANCE and cost us the sender.
    private static let junkLinePatterns = [
        "presorted", "first class", "first-class", "u.s. postage", "us postage",
        "postage paid", "permit no", "auto sort", "address service requested",
        "return service requested", "forwarding service", "electronic service",
        "important information enclosed", "confidential",
    ]

    /// Headlines the letter shouts before it says who is shouting. Taking one of
    /// these as the sender turns a scam into "Final Notice."
    private static let headlinePatterns = [
        "final notice", "important", "urgent", "notice of", "second notice",
        "time sensitive", "open immediately", "enclosed", "act now",
        "explanation of benefits", "do not discard", "response requested",
        "dear", "estimado", "estimada", "delivery notice", "aviso",
    ]

    private static func findSender(_ lines: [String]) -> String? {
        var candidates: [(Int, String)] = []
        // The sender's name is nearly always in the first handful of lines, above
        // the address block. Walk them and take the first that reads like a name
        // rather than a barcode, a ZIP line, a postal instruction or a headline.
        for (index, line) in lines.prefix(8).enumerated() {
            let lower = line.lowercased()
            if junkLinePatterns.contains(where: { containsPhrase(lower, $0) }) { continue }
            if headlinePatterns.contains(where: { containsPhrase(lower, $0) }) { continue }
            if amountCues.contains(where: lower.contains) { continue }
            if looksLikeAddress(line) { continue }
            if isSentence(line) { continue }
            // Past the first few lines we're into the body, where only a shouting
            // letterhead is still plausibly the sender.
            if index > 2, !isMostlyUppercase(line) { continue }

            let letters = line.filter { $0.isLetter }.count
            let words = line.split(separator: " ").count
            guard letters >= 4, line.count <= 45 else { continue }
            // Mostly letters, not a serial number or an account line
            guard Double(letters) / Double(max(line.count, 1)) > 0.6 else { continue }
            guard words <= 6 else { continue }

            candidates.append((index, trimTail(line)))
        }

        // Highest line wins. Tried "longest line" instead, to survive a scan that
        // splits a letterhead — but it turned CHASE / CARDMEMBER SERVICE into
        // "Cardmember Service." The name is at the top; trust that.
        if let first = candidates.first {
            return tidy(dropLeadingFiller(first.1))
        }
        // Nothing usable up top — a personal letter opens "Dear Neighbor" and only
        // says who wrote it at the bottom. Read the signature block instead.
        return signatureName(lines)
    }

    /// Cuts the account/reference junk that OCR merges onto the letterhead line
    /// when a bill is laid out in columns.
    private static func trimTail(_ line: String) -> String {
        let markers = ["account", "acct", "policy", "invoice", "customer", "no.", "#"]
        var out = line
        for marker in markers {
            if let r = out.lowercased().range(of: "\\b" + marker, options: .regularExpression) {
                let head = String(out[out.startIndex..<r.lowerBound])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -,:|"))
                if head.filter({ $0.isLetter }).count >= 4 { out = head }
            }
        }
        return out
    }

    private static func signatureName(_ lines: [String]) -> String? {
        let closings = ["sincerely", "regards", "thank you", "love", "yours truly", "atentamente"]
        for (i, line) in lines.enumerated() {
            guard closings.contains(where: { line.lowercased().hasPrefix($0) }) else { continue }
            for candidate in lines.dropFirst(i + 1).prefix(2) {
                let letters = candidate.filter { $0.isLetter }.count
                let words = candidate.split(separator: " ").count
                if letters >= 3, words <= 4, !looksLikeAddress(candidate) {
                    return tidy(candidate)
                }
            }
        }
        return nil
    }

    /// Substring match that respects word boundaries, so "auto" doesn't fire
    /// inside "automobile".
    private static func containsPhrase(_ haystack: String, _ phrase: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        return haystack.range(of: "\\b" + escaped + "\\b", options: .regularExpression) != nil
    }

    private static func looksLikeAddress(_ line: String) -> Bool {
        let lower = line.lowercased()
        // "SPRINGFIELD, IL 62704" / "123 Main Street" / "P.O. Box 4100"
        if line.range(of: #"\b\d{5}(-\d{4})?\b"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"^\s*\d+\s+\S+"#, options: .regularExpression) != nil { return true }
        if lower.hasPrefix("p.o. box") || lower.hasPrefix("po box") { return true }
        // A bare "ARCATA CA" city line, ZIP cut off by the crop
        if line.range(of: #"(?i)^[A-Za-z .']{3,20},?\s+[A-Z]{2}\.?$"#,
                      options: .regularExpression) != nil { return true }
        return false
    }

    /// Prose, not a letterhead. "We appreciate your patience." is not a sender.
    private static func isSentence(_ line: String) -> Bool {
        let words = line.split(separator: " ").count
        return words >= 3 && line.hasSuffix(".") && line.contains(where: { $0.isLowercase })
    }

    private static func isMostlyUppercase(_ line: String) -> Bool {
        let letters = line.filter { $0.isLetter }
        guard !letters.isEmpty else { return false }
        return Double(letters.filter { $0.isUppercase }.count) / Double(letters.count) > 0.7
    }

    /// OCR reads a 1 for an l and a 0 for an O inside words. Left alone, the voice
    /// says "sanitat-one-on serv-one-ce". Only ever applied to the sender name —
    /// never to an amount or a date, where a digit is the whole point.
    private static func repairOCRDigits(_ word: String) -> String {
        let letters = word.filter { $0.isLetter }.count
        guard letters >= 2, word.contains(where: { $0.isNumber }) else { return word }
        let chars = Array(word)
        var out = ""
        for (i, c) in chars.enumerated() {
            let prevIsLetter = i > 0 && chars[i - 1].isLetter
            let nextIsLetter = i + 1 < chars.count && chars[i + 1].isLetter
            if prevIsLetter, nextIsLetter, c == "1" { out.append("i") }
            else if prevIsLetter, nextIsLetter, c == "0" { out.append("o") }
            else if prevIsLetter, nextIsLetter, c == "5" { out.append("s") }
            else { out.append(c) }
        }
        return out
    }

    /// A wrapped letterhead hands back "AND ELECTRIC COMPANY" — starting a spoken
    /// sentence on a conjunction sounds broken, so drop it.
    private static func dropLeadingFiller(_ line: String) -> String {
        let filler = ["and", "of", "the", "de", "y", "&"]
        var words = line.split(separator: " ").map(String.init)
        while let first = words.first, filler.contains(first.lowercased()), words.count > 1 {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }

    /// SHOUTING LETTERHEAD becomes Shouting Letterhead so the voice doesn't spell it.
    private static func tidy(_ line: String) -> String {
        let repaired = line.split(separator: " ")
            .map { repairOCRDigits(String($0)) }
            .joined(separator: " ")
        let cleaned = repaired.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;|*"))
        let letters = cleaned.filter { $0.isLetter }
        let uppers = letters.filter { $0.isUppercase }.count
        guard letters.count > 0, Double(uppers) / Double(letters.count) > 0.8 else { return cleaned }
        return cleaned
            .split(separator: " ")
            .map { word -> String in
                // Keep real acronyms shouting (PG&E, IRS, AT&T, USPS) but not
                // ordinary words that happen to be short — "GAS AND" must not
                // survive as "GAS AND".
                if isAcronym(String(word)) { return String(word) }
                let w = String(word).lowercased()
                return w.prefix(1).uppercased() + w.dropFirst()
            }
            .joined(separator: " ")
    }

    /// An acronym keeps its capitals: it has a symbol in it (PG&E, AT&T) or no
    /// vowels at all (IRS, USPS, DMV). "GAS" and "AND" are neither.
    private static func isAcronym(_ word: String) -> Bool {
        guard word.count <= 5, word.allSatisfy({ !$0.isLowercase }) else { return false }
        if word.contains("&") || word.contains(".") { return true }
        return !word.lowercased().contains(where: { "aeiou".contains($0) })
    }

    // MARK: - How much

    private static let amountCues = [
        "amount due", "total due", "payment due", "balance due", "pay this amount",
        "amount enclosed", "minimum payment", "total amount", "please pay", "past due",
        "balance", "cantidad a pagar", "total a pagar", "importe a pagar",
        "in the amount of",
    ]

    private static func findAmount(_ lines: [String], kind: Kind) -> String? {
        // A statement's headline number is what you have, not what you owe.
        let cues = kind == .statement
            ? ["ending balance", "new balance", "current balance"]
            : amountCues

        // Walk the cues in order of how specific they are, not the lines in order
        // of where they sit. Otherwise "Previous Balance $112.40" at the top wins
        // over "Amount Due $0.00" further down, and a paid-off bill reads as owing.
        for cue in cues {
        for (i, line) in lines.enumerated() {
            let l = line.lowercased()
            guard l.contains(cue) else { continue }
            // History lines, not what's owed now.
            if ["previous", "prior", "last statement", "payment received", "payments"]
                .contains(where: l.contains) { continue }
            if let hit = currency(in: line) { return hit }
            for next in lines.dropFirst(i + 1).prefix(2) {
                if let hit = currency(in: next) { return hit }
            }
            // OCR drops the dollar sign constantly ("Amount Due: 84.12"). On a
            // line that already told us it's the amount, a bare figure is safe.
            if let bare = bareAmount(in: line) { return bare }
            for next in lines.dropFirst(i + 1).prefix(1) {
                if let bare = bareAmount(in: next) { return bare }
            }
        }
        }

        // No labelled figure. Guessing the biggest number on the page is only safe
        // on a bill; on a summons it reads out the maximum fine, and on a rent
        // notice it reads the OLD rent. Say nothing instead.
        guard kind == .bill else { return nil }
        // Live OCR delivers the page out of order, so "Amount Due" and the figure
        // often land nowhere near each other — and the dollar sign frequently
        // doesn't survive the scan. Both forms count here or a bill reads out its
        // due date with no amount, which is exactly the wrong half.
        let all = lines.compactMap { currency(in: $0) ?? bareAmount(in: $0) }
        return all.max { value($0) < value($1) }
    }

    private static func currency(in line: String) -> String? {
        guard let r = line.range(of: #"\$\s?\d[\d,]*(\.\d{2})?"#, options: .regularExpression)
        else { return nil }
        return String(line[r]).replacingOccurrences(of: " ", with: "")
    }

    /// A figure with cents but no dollar sign, on a line that already said what it
    /// is. Requires the decimal so account numbers and dates can't slip through.
    private static func bareAmount(in line: String) -> String? {
        guard let r = line.range(of: #"(?<![\d/.-])\d[\d,]*\.\d{2}(?![\d/-])"#,
                                 options: .regularExpression) else { return nil }
        return "$" + String(line[r])
    }

    private static func value(_ s: String) -> Double {
        Double(s.filter { $0.isNumber || $0 == "." }) ?? 0
    }

    // MARK: - By when

    private static let months = ["january", "february", "march", "april", "may", "june",
                                 "july", "august", "september", "october", "november", "december",
                                 "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept",
                                 "oct", "nov", "dec"]

    private static func findDueDate(_ flat: String, lower: String) -> String? {
        // Only report a date we can tie to a deadline. A letter is full of dates —
        // the statement date, the period, a copyright year — and reading the wrong
        // one out loud is worse than reading none.
        let cues = ["due date", "due by", "due on", "payment due", "pay by",
                    "on or before", "respond by", "report on", "pick up by",
                    "appointment on", "scheduled for", "effective", "due", "expires",
                    "fecha de vencimiento", "vence el", "antes del"]
        for cue in cues {
            guard let cueRange = lower.range(of: cue) else { continue }
            let tail = String(flat[cueRange.upperBound...].prefix(60))
            if let date = firstDate(in: tail) { return date }
        }
        return nil
    }

    private static func firstDate(in text: String) -> String? {
        let patterns = [
            #"(?i)\b(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)\.?\s+\d{1,2}(st|nd|rd|th)?(,?\s+\d{4})?"#,
            // Spanish: "8 de septiembre de 2026"
            #"(?i)\b\d{1,2}\s+de\s+(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre)(\s+de\s+\d{4})?"#,
            #"\b\d{1,2}/\d{1,2}/\d{2,4}\b"#,
            #"\b\d{4}-\d{2}-\d{2}\b"#,
        ]
        for p in patterns {
            if let r = text.range(of: p, options: .regularExpression) {
                return String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
            }
        }
        return nil
    }

    // MARK: - The sentence

    private static func speak(sender: String?, kind: Kind, amount: String?, due: String?,
                              lines: [String]) -> String {
        if kind == .advertisement {
            let who = sender.map { "\($0). " } ?? ""
            return "\(who)Advertisement. Nothing is due."
        }
        if kind == .benefits {
            let who = sender.map { "\($0). " } ?? ""
            return "\(who)Explanation of benefits. This is not a bill."
        }

        // A paid-off bill is the good news in the stack — say so plainly instead of
        // reading out "zero dollars and zero cents."
        if let amount, value(amount) == 0 {
            let who = sender.map { "\($0). " } ?? ""
            return "\(who)\(kind.spoken). Nothing is due."
        }
        if kind == .refund {
            let who = sender.map { "\($0). " } ?? ""
            let sum = amount.map { "\($0) is coming to you." } ?? "Money is coming to you."
            return "\(who)Refund. \(sum)"
        }

        // No bill facts anywhere. Either we're mid-scan, or this simply isn't a
        // bill — a letter, an article, a flyer. Try a prose preview before giving
        // up, because "hold steady" is wrong and useless for a page of writing.
        if amount == nil, kind == .unknown || kind == .delivery {
            // A date alone doesn't make a page a bill — "the week of October 6"
            // in a school notice is not a deadline. Preview the writing, and
            // mention the date afterwards if we found one.
            if let preview = prosePreview(lines, sender: sender) {
                return due.map { "\(preview) It mentions \($0)." } ?? preview
            }
            if due == nil { return "Still reading. Hold the letter steady." }
        }

        var parts: [String] = []
        if let sender { parts.append(sender) }
        // Only name the kind when we actually recognized one — "Letter" adds
        // nothing next to a sender we already read out.
        if kind != .unknown { parts.append(kind.spoken) }

        if let amount, let due {
            parts.append("\(amount), due \(due)")
        } else if let amount {
            parts.append(amount)
        } else if let due {
            // Starts its own sentence here, so it gets a capital.
            parts.append(kind == .appointment ? "On \(due)" : "Due \(due)")
        }

        // A bill with a date and no amount is the wrong half of the answer, and
        // silence about it reads as "there is no amount." Say what's missing so
        // the person knows to move the camera rather than trusting a half-read.
        if kind == .bill, amount == nil {
            parts.append("I can't read the amount yet")
        }

        // One fact is still worth saying. "$84.12" alone beats "I couldn't tell."
        if parts.isEmpty { return "Still reading. Hold the letter steady." }
        return parts.joined(separator: ". ") + "."
    }
}
