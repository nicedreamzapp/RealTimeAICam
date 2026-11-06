import UIKit

/// Short screen cues from the first-time-user tests (2026-11-04), each said ONCE: VoiceOver
/// announces it when VoiceOver is running, the app's own voice says it when it is not.
/// Mirrors Android's UiCue.
enum UICue {
    /// English keys: `say` puts them in the app's language.
    static let home = "Home"
    static let readHint = "Point the camera at some text"
    /// Looked up by key when said (`line`), not through L() at the call. Listed through L()
    /// here only so ios/tools/es-strings.py counts them; never read at run time. A Spanish app
    /// said both in English with the Spanish voice until they were in the catalog (2026-11-05).
    static let keysSaidByKey = [L("Home"), L("Point the camera at some text")]
    /// How long Read waits after opening before its hint, so text found right away wins.
    static let readHintDelay: TimeInterval = 1.2
    /// After "Home", the pause before VoiceOver's focus moves to Settings (which cuts speech off).
    static let homeFocusDelay: TimeInterval = 0.9
    /// The guide sheet slides up first; its heading gets VoiceOver's focus once it is in place.
    static let guideFocusDelay: TimeInterval = 0.6

    /// Set by the Language pill when it swaps Read for the translator: the new screen says the
    /// language choice instead of the opening hint.
    static var readerSwitchedByPill = false

    enum Route: Equatable { case voiceOver, appVoice }

    static func route(voiceOverRunning: Bool) -> Route { voiceOverRunning ? .voiceOver : .appVoice }

    /// Read's opening hint: only when nothing is shown or being read yet, and not when the
    /// screen opened because the Language pill switched readers.
    static func shouldSayReadHint(hasText: Bool, speaking: Bool, openedByLanguagePill: Bool) -> Bool {
        !hasText && !speaking && !openedByLanguagePill
    }

    /// Delay before "Home" after the guide closes: VoiceOver's own screen change after a sheet
    /// dismiss swallows an announcement posted right away (11/04 review).
    static let homeCueDelay: TimeInterval = 0.6

    /// The cue's words and their language. The app's own Spanish ships in the app, so a Spanish
    /// app always says the bundled line, with no download (2026-11-05); an English app with Your
    /// language in another language still goes through the translator. Same as Android cue().
    static func line(_ english: String) async -> (text: String, lang: String) {
        let app = AppLang.code
        if app != AppLang.english { return (AppLang.text(english, in: app), app) }
        if YourLanguage.activeCode == YourLanguageRules.english { return (english, YourLanguageRules.english) }
        return await YourLanguage.intoActive(english)
    }

    /// Says `english` once, in Your language when it is set (11/04 review): a VoiceOver
    /// announcement when VoiceOver runs, else `appVoice(text, language)`. Nothing is said if
    /// the calling task was cancelled meanwhile (the screen was left).
    /// `stillWanted` is asked again once the translation is back (round-2 review): a cue that
    /// comes back late, after leaving the screen or once reading started, is dropped.
    @MainActor
    static func say(_ english: String, stillWanted: () -> Bool = { true },
                    appVoice: (_ text: String, _ language: String) -> Void) async {
        let out = await line(english)
        guard !Task.isCancelled, stillWanted() else { return }
        switch route(voiceOverRunning: UIAccessibility.isVoiceOverRunning) {
        case .voiceOver:
            let line = NSAttributedString(string: out.text,
                                          attributes: [.accessibilitySpeechLanguage: out.lang])
            UIAccessibility.post(notification: .announcement, argument: line)
        case .appVoice:
            appVoice(out.text, out.lang)
        }
    }
}
