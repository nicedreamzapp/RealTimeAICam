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

    /// Says `line` once: a VoiceOver announcement when VoiceOver runs, else `appVoice()`.
    static func say(_ line: String, appVoice: () -> Void) {
        switch route(voiceOverRunning: UIAccessibility.isVoiceOverRunning) {
        case .voiceOver:
            UIAccessibility.post(notification: .announcement, argument: line)
        case .appVoice:
            appVoice()
        }
    }
}
