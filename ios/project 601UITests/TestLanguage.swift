import Foundation

/// UI tests run in English or, with the simulator set to Spanish, in Spanish (2026-11-05).
/// `T("Read")` is the label the app shows in the simulator's language, taken straight from the
/// app's string catalog in the source tree (a simulator can read the Mac's files), so the same
/// tests check both languages.
enum TestLanguage {
    /// The simulator's language. A test that forces the app's language another way (launch
    /// arguments, Your language) must pick its labels itself.
    static var isSpanish: Bool {
        Locale.preferredLanguages.first?.hasPrefix("es") == true
    }

    private static let catalog: [String: String] = {
        let here = URL(fileURLWithPath: #filePath)
        let file = here.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("project 601/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in strings {
            if let v = value as? [String: Any],
               let loc = v["localizations"] as? [String: Any],
               let es = loc["es"] as? [String: Any],
               let unit = es["stringUnit"] as? [String: Any],
               let s = unit["value"] as? String { out[key] = s }
        }
        return out
    }()

    /// `english` in Spanish (the English itself when it has no entry).
    static func spanish(_ english: String) -> String { catalog[english] ?? english }

    /// Format keys: `T("%@ → Eng", "French")`.
    static func spanish(_ english: String, _ args: CVarArg...) -> String {
        String(format: spanish(english), arguments: args)
    }
}

/// The app's label for `english` in the language this test run uses.
func T(_ english: String) -> String {
    TestLanguage.isSpanish ? TestLanguage.spanish(english) : english
}

func T(_ english: String, _ args: CVarArg...) -> String {
    String(format: TestLanguage.isSpanish ? TestLanguage.spanish(english) : english, arguments: args)
}
