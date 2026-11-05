import Combine
import Foundation
import SwiftUI

/// The language of the app's own words: buttons, menus, alerts, VoiceOver labels, the guide,
/// and every line the app itself speaks (2026-11-05, for a blind Spanish speaker).
///
/// Spanish when the phone (or the app's own language in iOS Settings) is Spanish, OR when
/// "Your language" is Spanish; English otherwise. Spanish ships inside the app (Localizable.xcstrings),
/// so unlike Your language's translator nothing downloads.
///
/// How it works: every user-visible string goes through `L("English text")`, which looks the
/// English up in the chosen language's table. One explicit lookup instead of SwiftUI's
/// automatic LocalizedStringKey, so the Your-language override works even when the phone is
/// English, and the same words reach VoiceOver, the screen and the app's voice.
/// Mirrors Android AppLang.kt.
enum AppLang {
    static let english = "en"
    static let spanish = "es"
    /// Languages the app's own words exist in.
    static let shipped: Set<String> = [english, spanish]

    /// The rule, pure for tests: the phone's (or the app's per-app) language first, then Your language.
    static func uiCode(appLanguage: String?, yourLanguage: String) -> String {
        if let a = appLanguage, YourLanguageRules.normalize(a) == spanish { return spanish }
        return yourLanguage == spanish ? spanish : english
    }

    /// Your language as saved (or as it follows the phone), readable from any thread.
    private static var savedYourLanguage: String {
        YourLanguageRules.resolve(saved: UserDefaults.standard.string(forKey: YourLanguage.key),
                                  phoneLanguage: YourLanguage.phoneLanguage,
                                  translatorAvailable: YourLanguage.translatorAvailable)
    }

    /// The language iOS picked for this app: the phone's, or the per-app choice in Settings.
    static var appLanguage: String? { Bundle.main.preferredLocalizations.first }

    #if DEBUG
    /// Tests only: `-rtcamUILanguage es|en` (a launch argument, or set in a unit test) fixes the
    /// answer, whatever the phone and Your language say.
    static let forcedKey = "rtcamUILanguage"
    #endif

    /// "es" or "en". Safe from any thread.
    static var code: String {
        #if DEBUG
        if let forced = UserDefaults.standard.string(forKey: forcedKey), shipped.contains(forced) { return forced }
        #endif
        return uiCode(appLanguage: appLanguage, yourLanguage: savedYourLanguage)
    }

    static var isSpanish: Bool { code == spanish }

    static var locale: Locale { Locale(identifier: code) }

    private static let bundleLock = NSLock()
    private nonisolated(unsafe) static var bundles: [String: Bundle] = [:]

    static func bundle(_ c: String) -> Bundle {
        bundleLock.lock(); defer { bundleLock.unlock() }
        if let b = bundles[c] { return b }
        let b = Bundle.main.path(forResource: c, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.main
        bundles[c] = b
        return b
    }

    /// `english` in language `c` (the English itself when it has no entry).
    static func text(_ english: String, in c: String) -> String {
        guard c != Self.english, !english.isEmpty else { return english }
        return bundle(c).localizedString(forKey: english, value: english, table: nil)
    }

    /// True when the catalog has a Spanish line for `english` (tests and the cue path).
    static func hasSpanish(_ english: String) -> Bool {
        bundle(spanish).localizedString(forKey: english, value: "\u{1}", table: nil) != "\u{1}"
    }
}

/// The app's own words in the app's language. `english` is the key: keep it identical to the
/// catalog entry. With arguments it is a format (`%@` text, `%d`/`%ld` whole numbers, `%%` a percent sign).
func L(_ english: String) -> String {
    AppLang.text(english, in: AppLang.code)
}

func L(_ english: String, _ args: CVarArg...) -> String {
    let c = AppLang.code
    return String(format: AppLang.text(english, in: c), locale: Locale(identifier: c), arguments: args)
}

/// Re-renders the screens that hold it when the app's language changes (Your language picked
/// in Settings). The phone's language only changes with a relaunch, so it needs no watching.
@MainActor
final class AppLangObserver: ObservableObject {
    static let shared = AppLangObserver()
    @Published private(set) var code = AppLang.code
    private var sub: AnyCancellable?

    private init() {
        sub = YourLanguage.shared.$code
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // $code fires before the stored value changes: read it on the next turn.
                DispatchQueue.main.async { self?.code = AppLang.code }
            }
    }
}
