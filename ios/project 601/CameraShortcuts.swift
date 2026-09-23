import AppIntents
import Combine

/// Siri, Shortcuts, Spotlight and the Action Button can open the app straight
/// into a camera screen, so nobody has to find the app and then find the button.
/// Matt, 2026-09-22: "Hey Siri, what's this in RealTime AI Cam" should land on
/// What's this?, ready to point.
@MainActor
final class ShortcutRouter: ObservableObject {
    static let shared = ShortcutRouter()

    /// Set by an intent, cleared by ContentView once it has switched screens.
    /// On a cold launch the intent can run before ContentView exists, so the
    /// request waits here until the view picks it up.
    @Published var pendingMode: AppMode?

    func open(_ mode: AppMode) {
        pendingMode = mode
    }
}

struct WhatsThisIntent: AppIntent {
    static let title: LocalizedStringResource = "What's this?"
    static let description = IntentDescription("Opens What's this?, ready to point at a page, a bill, a package or a room.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutRouter.shared.open(.mail)
        return .result()
    }
}

struct HelpMeAimIntent: AppIntent {
    static let title: LocalizedStringResource = "Help Me Aim"
    static let description = IntentDescription("Opens Help Me Aim, which talks you into the shot and then takes it.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutRouter.shared.open(.helpMeAim)
        return .result()
    }
}

struct ReadTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Read text"
    static let description = IntentDescription("Opens the text reader, which reads what the camera sees out loud.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutRouter.shared.open(.ocrEnglish)
        return .result()
    }
}

struct TranslateIntent: AppIntent {
    static let title: LocalizedStringResource = "Translate"
    static let description = IntentDescription("Opens the translator, which reads text in another language out loud in English.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutRouter.shared.open(.ocrSpanish)
        return .result()
    }
}

struct ObjectDetectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Object Detection"
    static let description = IntentDescription("Opens Object Detection, which names the things around you out loud.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutRouter.shared.open(.objectDetection)
        return .result()
    }
}

/// These work the moment the app is installed, with no setup: Siri hears the
/// phrases, Spotlight lists them, and each one can go on the Action Button.
/// Every phrase has to carry the app's name, Apple's rule.
struct CameraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatsThisIntent(),
            phrases: [
                "What's this in \(.applicationName)",
                "What is this in \(.applicationName)",
                "Describe this with \(.applicationName)",
                "What's in front of me in \(.applicationName)",
            ],
            shortTitle: "What's this?",
            systemImageName: "questionmark.viewfinder"
        )
        AppShortcut(
            intent: HelpMeAimIntent(),
            phrases: [
                "Help me aim with \(.applicationName)",
                "Help me take a picture with \(.applicationName)",
                "Help me aim in \(.applicationName)",
            ],
            shortTitle: "Help Me Aim",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: ReadTextIntent(),
            phrases: [
                "Read this with \(.applicationName)",
                "Read text with \(.applicationName)",
                "Read this in \(.applicationName)",
            ],
            shortTitle: "Read text",
            systemImageName: "text.viewfinder"
        )
        AppShortcut(
            intent: TranslateIntent(),
            phrases: [
                "Translate this with \(.applicationName)",
                "Translate with \(.applicationName)",
            ],
            shortTitle: "Translate",
            systemImageName: "character.bubble"
        )
        AppShortcut(
            intent: ObjectDetectionIntent(),
            phrases: [
                "What's around me in \(.applicationName)",
                "Find objects with \(.applicationName)",
                "Start object detection in \(.applicationName)",
            ],
            shortTitle: "Object Detection",
            systemImageName: "eye"
        )
    }
}
