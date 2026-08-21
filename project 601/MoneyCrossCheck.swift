import Foundation

/// Second opinion on dollar amounts. A small vision model can read "$128.40"
/// as "$126.40" and say it with full confidence; Apple's text recognizer is
/// far better at digits. When the two disagree, the sentence is hedged so the
/// listener knows to scan again rather than pay the wrong number.
enum MoneyCrossCheck {
    static let hedge = " I'm not certain of the amount; hold the phone closer to the number and scan again."

    /// Comma-grouped form first, then a plain digit run. (A naive
    /// `\d{1,3}(,\d{3})*|\d+` alternation stops at "$123" inside "$1234.50".)
    private static let pattern = #"\$\s?(\d{1,3}(,\d{3})+|\d+)(\.\d{2})?"#
    private static let regex = try? NSRegularExpression(pattern: pattern)

    /// Every dollar amount in `text`, normalised to digits-and-dot ("1,234.50" -> "1234.50").
    static func amounts(in text: String) -> [String] {
        guard let regex else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            ns.substring(with: m.range)
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: " ", with: "")
        }
    }

    /// - Returns: the sentence to speak, and whether the model's amount(s)
    ///   agreed with OCR. `agreed` is nil when there was nothing to compare
    ///   (OCR saw no amounts, or the sentence has none).
    static func reconcile(sentence: String, ocrText: String) -> (sentence: String, agreed: Bool?) {
        let ocr = Set(amounts(in: ocrText))
        guard !ocr.isEmpty else { return (sentence, nil) }
        let said = amounts(in: sentence)
        guard !said.isEmpty else { return (sentence, nil) }
        // "Agreed" means every amount the model spoke was also printed on the
        // page. One invented number is enough to hedge the whole sentence.
        if said.allSatisfy({ ocr.contains($0) }) { return (sentence, true) }
        var out = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.hasSuffix(".") && !out.hasSuffix("!") && !out.hasSuffix("?") { out += "." }
        return (out + hedge, false)
    }

    #if DEBUG
    /// Cheap self-check, run once from a debug build; mirrors the unit test so
    /// the helper is covered even if the test target is not built.
    static func selfCheck() -> Bool {
        let a = reconcile(sentence: "Your bill is $1,234.50, due June 3.", ocrText: "AMOUNT DUE $ 1,234.50")
        let b = reconcile(sentence: "Your bill is $126.40.", ocrText: "Total $128.40")
        let c = reconcile(sentence: "Your bill is $126.40.", ocrText: "no numbers here")
        let d = reconcile(sentence: "An advertisement from a car dealer.", ocrText: "$19,999")
        return a.agreed == true && a.sentence.hasSuffix("June 3.")
            && b.agreed == false && b.sentence.hasSuffix(hedge)
            && c.agreed == nil && c.sentence == "Your bill is $126.40."
            && d.agreed == nil
    }
    #endif
}
