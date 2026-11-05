import UIKit

/// Short screen cues from the first-time-user tests (2026-11-04), each said ONCE: VoiceOver
/// announces it when VoiceOver is running, the app's own voice says it when it is not.
/// Mirrors Android's UiCue.
enum UICue {
    static let home = "Home"
    static let readHint = "Point the camera at some text"
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

    /// Says `english` once, in Your language when it is set (11/04 review): a VoiceOver
    /// announcement when VoiceOver runs, else `appVoice(text, language)`. Nothing is said if
    /// the calling task was cancelled meanwhile (the screen was left).
    @MainActor
    static func say(_ english: String, appVoice: (_ text: String, _ language: String) -> Void) async {
        let out: (text: String, lang: String) = YourLanguage.activeCode == YourLanguageRules.english
            ? (english, YourLanguageRules.english)
            : await YourLanguage.intoActive(english)
        guard !Task.isCancelled else { return }
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
