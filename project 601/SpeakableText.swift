import Foundation

/// Rewrites text the camera read so the voice says it the way a person would.
/// Apple's voice guesses at numbers and abbreviations on its own and guesses
/// badly on signs and mail: "393 Westgate Dr" came out "three hundred
/// ninety-three Westgate doctor", a phone number came out as one huge number,
/// and a card number got read in full (Matt, 2026-09-16).
///
/// Only what gets SPOKEN goes through this; the text on screen and the text
/// that gets copied stay exactly as the camera read them.
enum SpeakableText {

    static func make(_ input: String) -> String {
        var s = input
        s = stripFormatting(s)
        s = joinLines(s)
        // "Citation No. 802214557", "Factura No. 004512": "no" would be read as the word.
        s = s.replacingOccurrences(of: #"\b[Nn][Oo]\.\s*(?=#?\s?\d)"#, with: "number ", options: .regularExpression)
        s = tooLongToSay(s)
        s = maskedNumbers(s)
        s = europeanAmounts(s)
        s = internationalPrefix(s)
        s = phoneNumbers(s)
        s = zipCodes(s)
        s = poBox(s)
        s = streetAddresses(s)
        s = unitWords(s)
        s = monthYear(s)
        s = mixedCodes(s)
        s = labeledNumbers(s)
        s = digitRuns(s)
        s = fractions(s)
        // "TR# 7731", "Order #12": the voice may say "pound" or "hashtag".
        s = s.replacingOccurrences(of: "#", with: " number ")
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,.:;])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?:,\s*){2,}"#, with: ", ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Formatting

    /// Things with no business coming out of a speaker: the model's markdown
    /// ("**Due:**", "- item", "## Bill"), emoji, dot leaders and rule lines on
    /// menus and receipts ("Burger.......14.50", "=========="), and the path
    /// part of a web address ("ineedhemp.com/how-to-clean-..." is read slash by slash).
    static func stripFormatting(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"__(.+?)__"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?m)^\s*#{1,6}\s+"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?m)^\s*(?:[-*•▪◦·]|\d{1,2}[.)])\s+"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"`+"#, with: "", options: .regularExpression)
        // Emoji and pictographs (keeps letters, digits, punctuation, currency).
        out = String(String.UnicodeScalarView(out.unicodeScalars.filter { u in
            !(u.properties.isEmojiPresentation || (u.properties.isEmoji && u.value > 0x2000 && !"#*".unicodeScalars.contains(u))
              || u.value == 0xFE0F || u.value == 0x200D)
        }))
        // Web addresses: say the site, not the path.
        out = replace(out, #"(?i)\b(?:https?://)?(?:www\.)?((?:[a-z0-9-]+\.)+(?:com|org|net|gov|edu|io|co|us|mx|es|app|ai)\b)(?:/[^\s]*)?"#) { m in
            let site = String(m.groups[0] ?? "")
            return m.whole.contains("/") ? "\(site) link" : String(m.whole)
        }
        // Dot leaders and rule lines are a pause.
        out = out.replacingOccurrences(of: #"\s*(?:\.\s?){3,}\s*(?=\S)"#, with: ", ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[-=_~]{3,}|\*{3,}(?![*\s]*\d)"#, with: " ", options: .regularExpression)
        return out
    }

    // MARK: - Lines

    /// A new line on a sign or an envelope is a pause, not a run-on. Without
    /// it "Westgate Dr" and "Eureka, CA" on the next line blur together.
    static func joinLines(_ s: String) -> String {
        let lines = s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > 1 else { return lines.first ?? "" }
        var out = ""
        for (i, line) in lines.enumerated() {
            out += line
            if i < lines.count - 1 {
                out += (line.last.map { ".,;:!?".contains($0) } ?? false) ? " " : ", "
            }
        }
        return out
    }

    // MARK: - Numbers

    private static let digitWords = ["zero", "one", "two", "three", "four",
                                     "five", "six", "seven", "eight", "nine"]
    private static let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen",
                                "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty",
                               "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// "805" -> "eight zero five"
    static func spelled(_ digits: Substring) -> String {
        digits.compactMap { $0.wholeNumberValue }.map { digitWords[$0] }.joined(separator: " ")
    }

    static func twoDigit(_ n: Int) -> String {
        if n < 10 { return digitWords[n] }
        if n < 20 { return teens[n - 10] }
        return n % 10 == 0 ? tens[n / 10] : "\(tens[n / 10])-\(digitWords[n % 10])"
    }

    /// House numbers the way people say them: 393 "three ninety-three",
    /// 1205 "twelve oh five", 2000 "two thousand", 45120 "four five one two zero".
    static func houseNumber(_ digits: String) -> String {
        guard let n = Int(digits) else { return digits }
        // "Tienda 0147": the zero is part of the name, say every digit.
        if digits.count > 1, digits.hasPrefix("0") { return spelled(Substring(digits)) }
        switch digits.count {
        case 1, 2:
            return twoDigit(n)
        case 3:
            let hi = n / 100, lo = n % 100
            if lo == 0 { return "\(digitWords[hi]) hundred" }
            return lo < 10 ? "\(digitWords[hi]) oh \(digitWords[lo])"
                           : "\(digitWords[hi]) \(twoDigit(lo))"
        case 4:
            let hi = n / 100, lo = n % 100
            if n % 1000 == 0 { return "\(digitWords[n / 1000]) thousand" }
            if lo == 0 { return "\(twoDigit(hi)) hundred" }
            return lo < 10 ? "\(twoDigit(hi)) oh \(digitWords[lo])"
                           : "\(twoDigit(hi)) \(twoDigit(lo))"
        default:
            return spelled(Substring(digits))
        }
    }

    /// The most digits worth reading out loud. Past this (tracking barcodes,
    /// serials) nobody follows along; the copy on screen has them all.
    static let maxSpokenDigits = 16

    /// More than 16 digits in a row, or a code longer than 16 characters:
    /// skip it and just say "long number" so the person knows something is there.
    static func tooLongToSay(_ s: String) -> String {
        var out = replace(s, #"(?<![\w$.,])\d(?:[ -]?\d)+(?![\w]|[.,]\d)"#) { m in
            m.filter(\.isNumber).count > maxSpokenDigits ? "long number" : String(m.whole)
        }
        out = replace(out, #"\b(?=[A-Z0-9-]*\d)(?=[A-Z0-9-]*[A-Z])[A-Z0-9][A-Z0-9-]{16,}\b"#) { m in
            let chars = m.filter { $0.isLetter || $0.isNumber }
            let digits = chars.filter(\.isNumber).count
            return chars.count > maxSpokenDigits && digits >= 3 ? "long number" : String(m.whole)
        }
        // Printed in spaced chunks, UPS style: "1Z 999 AA1 01 2345 6784".
        out = replace(out, #"\b[A-Z0-9]{1,6}(?:[ -][A-Z0-9]{1,6}){2,}\b"#) { m in
            let chars = m.filter { $0.isLetter || $0.isNumber }
            let digits = chars.filter(\.isNumber).count
            return chars.count > maxSpokenDigits && digits >= 10 ? "long number" : String(m.whole)
        }
        return out
    }

    /// Spanish and European money: "1.234,56 €" -> "1,234.56 €", "214,26 €" ->
    /// "214.26 €", "1.500.000" -> "1,500,000". Only shapes that can't be
    /// American: a dot every three digits, or a two-digit comma before €.
    static func europeanAmounts(_ s: String) -> String {
        var out = replace(s, #"(?<![\d.,])(\d{1,3}(?:\.\d{3})+)(?:,(\d{1,2}))?(?![\d.,]*\d)"#) { m in
            let g = m.groups
            let whole = (g[0] ?? "").replacingOccurrences(of: ".", with: ",")
            // "1.234" alone could be American 1.234; needs two groups or cents.
            if g[1] == nil, (g[0] ?? "").filter({ $0 == "." }).count < 2 { return String(m.whole) }
            return g[1].map { "\(whole).\($0)" } ?? whole
        }
        out = replace(out, #"(?<![\d.,])(\d+),(\d{2})(?=\s?(?:€|EUR|euros?\b))"#) { m in
            "\(m.groups[0] ?? "").\(m.groups[1] ?? "")"
        }
        return out
    }

    /// "+34 912 345 678" -> "plus three four, nine one two, ..."
    static func internationalPrefix(_ s: String) -> String {
        replace(s, #"\+\s?(\d{1,3})(?=[ .-]\d)"#) { m in "plus \(spelled(m.groups[0] ?? "")), " }
    }

    /// Masked numbers: "****4471", "XXX-XX-6789" -> "ending in four four seven one".
    /// A mask with nothing after it isn't said at all ("star star star...").
    /// "Checking ending in 4471" gets its last four as digits too.
    static func maskedNumbers(_ s: String) -> String {
        var out = replace(s, #"(?:[*•]{2,}|\bX{2,})(?:[ -]?(?:[*•]+|X+))*[ -]?(\d{2,4})\b"#) { m in
            "ending in \(spelled(m.groups[0] ?? ""))"
        }
        out = replace(out, #"[*•]{3,}"#) { _ in "" }
        out = replace(out, #"(?i)\b(ending in|ends in|last four|last 4)(:?\s*)(\d{4})\b"#) { m in
            "\(m.groups[0] ?? "") \(spelled(m.groups[2] ?? ""))"
        }
        return out
    }

    /// (707) 555-0142, 805-895-8967, 805.895.8967, 1-800-555-1234, +1 707 555 0142
    /// -> "eight zero five, eight nine five, eight nine six seven"
    static func phoneNumbers(_ s: String) -> String {
        let pattern = #"(?<![\w$])(?:\+?(1)[ .-]?)?\(?(\d{3})\)?[ .-]?(\d{3})[ .-](\d{4})(?!\w)"#
        return replace(s, pattern) { m in
            let parts = m.groups
            var said: [String] = []
            if let one = parts[0], !one.isEmpty { said.append("one") }
            for p in parts.dropFirst() { if let p { said.append(spelled(p)) } }
            return said.joined(separator: ", ")
        }
    }

    private static let states = "AL|AK|AZ|AR|CA|CO|CT|DE|DC|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|PR"

    /// "CA 95501" -> "C A, nine five five zero one". The state letters are
    /// spaced out because "CA" alone sometimes comes out as a word.
    static func zipCodes(_ s: String) -> String {
        replace(s, #"\b(\#(states))\.?,?\s+(\d{5})(?:-(\d{4}))?\b"#) { m in
            let g = m.groups
            let state = g[0].map { $0.map(String.init).joined(separator: " ") } ?? ""
            var out = "\(state), \(spelled(g[1] ?? ""))"
            if let plus4 = g[2] { out += ", \(spelled(plus4))" }
            return out
        }
    }

    static func poBox(_ s: String) -> String {
        replace(s, #"(?i)\bP\.?\s?O\.?\s+Box\s+(\d+)"#) { m in
            "P O Box \(houseNumber(String(m.groups[0] ?? "")))"
        }
    }

    private static let suffixes: [String: String] = [
        "dr": "Drive", "st": "Street", "ave": "Avenue", "av": "Avenue", "blvd": "Boulevard",
        "rd": "Road", "ln": "Lane", "ct": "Court", "pl": "Place", "pkwy": "Parkway",
        "hwy": "Highway", "cir": "Circle", "ter": "Terrace", "trl": "Trail", "sq": "Square",
        "cres": "Crescent", "expy": "Expressway", "fwy": "Freeway", "hts": "Heights",
    ]
    private static let directions: [String: String] = [
        "n": "North", "s": "South", "e": "East", "w": "West",
        "ne": "Northeast", "nw": "Northwest", "se": "Southeast", "sw": "Southwest",
    ]

    /// "393 Westgate Dr" -> "three ninety-three Westgate Drive"
    /// "1205 N Main St." -> "twelve oh five North Main Street"
    static func streetAddresses(_ s: String) -> String {
        let suffixAlt = suffixes.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let pattern = #"(?i)\b(\d{1,6})([A-Z])?\s+(?:(N|S|E|W|NE|NW|SE|SW)\.?\s+)?((?:[A-Z0-9][\w'-]*\s+){0,3}?(?:[A-Z][\w'-]*|\d+(?:st|nd|rd|th)))\s+(\#(suffixAlt))\b\.?(?:\s+(N|S|E|W|NE|NW|SE|SW)\b\.?)?"#
        var out = replace(s, pattern) { m in
            let g = m.groups
            // "Room 12 with Dr Smith" is not an address: real street names are
            // capitalized. All-caps signs pass because they have no lowercase.
            let name = g[3] ?? ""
            if name.split(separator: " ").contains(where: { $0.first?.isLowercase ?? false }) {
                return String(m.whole)
            }
            var said = houseNumber(String(g[0] ?? ""))
            if let letter = g[1] { said += " \(letter.uppercased())" }
            if let d = g[2], let word = directions[d.lowercased()] { said += " \(word)" }
            said += " \(g[3] ?? "")"
            if let suf = g[4], let word = suffixes[suf.lowercased()] { said += " \(word)" }
            if let d = g[5], let word = directions[d.lowercased()] { said += " \(word)" }
            return said
        }
        // No house number but clearly a street: "Westgate Dr," / "Main St" at
        // the end of a line. "Dr. Smith" still gets to be a doctor.
        out = replace(out, #"\b([A-Z][A-Za-z'-]+|\d+(?:st|nd|rd|th|ST|ND|RD|TH))\s+(Dr|DR|St|ST|Ave|AVE|Blvd|BLVD|Rd|RD|Ln|LN)\b\.?(?=\s*(?:[,;]|$))"#) { m in
            let g = m.groups
            let word = suffixes[(g[1] ?? "").lowercased()] ?? String(g[1] ?? "")
            return "\(g[0] ?? "") \(word)"
        }
        return out
    }

    /// Apt 4B, Ste 200, Unit 12, # 7 after an address
    static func unitWords(_ s: String) -> String {
        replace(s, #"(?i)\b(apt|ste|suite|unit|bldg|fl)\b\.?\s*#?\s*(\d+)([A-Z])?\b"#) { m in
            let g = m.groups
            let names = ["apt": "Apartment", "ste": "Suite", "suite": "Suite",
                         "unit": "Unit", "bldg": "Building", "fl": "Floor"]
            var said = "\(names[(g[0] ?? "").lowercased()] ?? "") \(houseNumber(String(g[1] ?? "")))"
            if let letter = g[2] { said += " \(letter.uppercased())" }
            return said
        }
    }

    /// A short number with a label in front is a name, not a quantity:
    /// "Store 1847" and "TR# 7731" say "eighteen forty-seven", "seventy-seven
    /// thirty-one", not "one thousand eight hundred forty-seven".
    static func labeledNumbers(_ s: String) -> String {
        let labels = #"#|No\.?|Number|Num\.?|Store|Flight|Flt\.?|Room|Rm\.?|Ext\.?|Order|Ticket|Invoice|Inv\.?|Gate|Bus|Route|Train|Check|Lot|Case|Claim|Unit|Space|Stall|Box|Locker|Table|Seat|Station"#
        return replace(s, #"(?i)\b((?:\#(labels))\s*#?\s*:?\s*)(?:([A-Z]{2})\s)?(\d{3,4})(?![\w%]|[.,:/]\d)"#) { m in
            let g = m.groups
            let code = g[1].map { "\($0) " } ?? ""
            return "\(g[0] ?? "")\(code)\(houseNumber(String(g[2] ?? "")))"
        }
    }

    /// Dates keep their normal reading ("9/16/2026", "2026-09-16").
    private static let dateShape = try! NSRegularExpression(
        pattern: #"^(?:\d{1,2}[-/]\d{1,2}[-/]\d{2,4}|\d{4}-\d{1,2}-\d{1,2})$"#)

    /// Anything that is an ID rather than an amount gets its digits read one at a
    /// time, keeping the groups it was printed in as pauses:
    /// "Order #203041" -> "number two zero three zero four one",
    /// "9400 1118 9922 3344" -> "nine four zero zero, one one one eight, ...".
    /// Amounts (commas, decimals, $), years and short numbers are left alone,
    /// and so are loose small numbers in a row ("Qty 2 12 50").
    static func digitRuns(_ s: String) -> String {
        replace(s, #"(?<![\w$.,:/])(#\s?)?(\d+(?:[ -]\d+)*)(?![\w%]|[.,:/]\d)"#) { m in
            let g = m.groups
            let run = String(g[1] ?? "")
            let prefix = g[0] == nil ? "" : "# "
            if dateShape.firstMatch(in: run, range: NSRange(run.startIndex..., in: run)) != nil {
                return String(m.whole)
            }
            let groups = run.split(whereSeparator: { $0 == " " || $0 == "-" })
            let total = groups.reduce(0) { $0 + $1.count }
            let bigGroups = groups.filter { $0.count >= 3 }.count
            // One printed block of 5+ digits, or several blocks that together read
            // as one ID: "4491027735-6", "94-3217765", or 3+ digit blocks, 8+ in all.
            let isID = groups.count == 1
                ? total >= 5
                : (bigGroups >= 2 && total >= 8) || groups.contains { $0.count >= 5 }
            if isID, total <= maxSpokenDigits {
                return prefix + groups.map(spelled).joined(separator: ", ")
            }
            // Not an ID ("Pages 3-5", "Qty 2 12 50"): leave it as printed.
            return String(m.whole)
        }
    }

    static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                             "August", "September", "October", "November", "December"]

    /// Card expiry and use-by dates: "VALID THRU 04/28" -> "April 2028",
    /// "Exp 09/2027" -> "September 2027". A bare "04/28" elsewhere is left alone
    /// (it could be a day). "18:00 hrs" drops the "hrs": the voice already says hours.
    static func monthYear(_ s: String) -> String {
        var out = replace(s, #"(?<![\d/])(0?[1-9]|1[0-2])/(20\d{2})(?![\d/])"#) { m in
            "\(monthNames[Int(m.groups[0] ?? "1")! - 1]) \(m.groups[1] ?? "")"
        }
        out = replace(out, #"(?i)\b((?:valid\s+thru|valid\s+through|good\s+thru|exp(?:ires|iration|\.)?|use\s+by|best\s+by)\s*:?\s*)(0?[1-9]|1[0-2])/(\d{2})(?![\d/])"#) { m in
            "\(m.groups[0] ?? "")\(monthNames[Int(m.groups[1] ?? "1")! - 1]) 20\(m.groups[2] ?? "")"
        }
        out = out.replacingOccurrences(of: #"(\d{1,2}:\d{2})\s*(?i:hrs?)\.?(?!\w)"#, with: "$1", options: .regularExpression)
        return out
    }

    /// "1/2 tableta" was on its way to "January second".
    static func fractions(_ s: String) -> String {
        let names = ["1/2": "one half", "1/3": "one third", "2/3": "two thirds", "1/4": "one quarter",
                     "3/4": "three quarters", "1/8": "one eighth"]
        let mixed = replace(s, #"(?<![\d/.,])(\d+)\s+1/2(?![\d/])"#) { m in "\(m.groups[0] ?? "") and a half" }
        return replace(mixed, #"(?<![\d/])(\d)/(\d)(?![\d/])"#) { m in
            names[String(m.whole)] ?? String(m.whole)
        }
    }

    private static let unitTail = try! NSRegularExpression(
        pattern: #"^\d+(?:MG|MCG|ML|G|KG|LB|LBS|OZ|IN|FT|CM|MM|MPH|GB|MB|TB|MAH|W|V|K|AM|PM|ST|ND|RD|TH|X)$"#)

    /// "US-101", "I-405", "SR-299" are road names, not codes.
    private static let highway = try! NSRegularExpression(pattern: #"^(?:US|I|SR|CA|HWY|RT)-\d{1,3}$"#)

    /// Codes that mix capital letters and digits: UPS "1Z999AA101234567",
    /// "INV-2026-00451", "SN A7B9C2D4E1". Read one character at a time.
    /// Needs 3+ digits so "N95", "B12", "4B" and "I-5" stay words.
    static func mixedCodes(_ s: String) -> String {
        replace(s, #"\b(?=[A-Z0-9-]*\d)(?=[A-Z0-9-]*[A-Z])[A-Z0-9](?:[A-Z0-9]|-(?=[A-Z0-9])){4,}\b"#) { m in
            let code = String(m.whole)
            let chars = code.filter { $0.isLetter || $0.isNumber }
            guard chars.filter(\.isNumber).count >= 3,
                  highway.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) == nil,
                  unitTail.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) == nil
            else { return code }
            return code.split(separator: "-").map { part in
                part.map { c in c.wholeNumberValue.map { digitWords[$0] } ?? String(c) }
                    .joined(separator: " ")
            }.joined(separator: ", ")
        }
    }

    // MARK: - Regex plumbing

    struct Match {
        let whole: Substring
        let groups: [Substring?]
        func filter(_ f: (Character) -> Bool) -> String { String(whole.filter(f)) }
    }

    static func replace(_ s: String, _ pattern: String, _ transform: (Match) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for r in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: r.range.location - last))
            let groups: [Substring?] = (1..<max(r.numberOfRanges, 1)).map { i in
                let gr = r.range(at: i)
                return gr.location == NSNotFound ? nil : Substring(ns.substring(with: gr))
            }
            out += transform(Match(whole: Substring(ns.substring(with: r.range)), groups: groups))
            last = r.range.location + r.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
