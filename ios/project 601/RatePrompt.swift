import StoreKit
import UIKit

/// "Rate this app" through Apple's own review sheet (Apple shows it at most three
/// times a year, and a person can switch it off for every app in Settings). Same
/// rule as Android RatePrompt.kt.
///
/// Rule (store brief 2026-11-04): asked ONLY right after a success moment, which here
/// is a result read aloud all the way through (a Read page, a translation, a What's
/// this? answer, a Help Me Aim description): counted when the voice finishes it, never
/// when it is stopped or cut off. Not before the 3rd success, never during the first
/// launch, at most once every 60 days (and 3 more successes since the last ask). No
/// "do you like the app?" screen first (Apple 5.6.1). Never over speech: it waits
/// until the app's voice is done, and gives VoiceOver a moment.
enum RatePrompt {
    static let firstAskAfter = 3
    static let moreResultsBeforeAskingAgain = 3
    static let daysBetweenAsks: Double = 60
    /// Launches before the first ask: never on the first one.
    static let minLaunches = 2

    private static let countKey = "ratePrompt.results"
    private static let askedAtKey = "ratePrompt.lastAskedAt"
    private static let countAtAskKey = "ratePrompt.resultsAtLastAsk"
    private static let launchesKey = "ratePrompt.launches"

    /// Pure rule, unit tested (same cases as Android).
    static func shouldAsk(results: Int, launches: Int, lastAskedAt: Date?, resultsAtLastAsk: Int, now: Date) -> Bool {
        guard launches >= minLaunches else { return false }
        guard let last = lastAskedAt else { return results >= firstAskAfter }
        return now.timeIntervalSince(last) >= daysBetweenAsks * 86_400
            && results - resultsAtLastAsk >= moreResultsBeforeAskingAgain
    }

    /// Once per app start.
    static func noteLaunch() {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: launchesKey) + 1, forKey: launchesKey)
    }

    private static var pending = false

    /// The line about to be spoken is a result. Call right before speaking it;
    /// it only counts once the voice has finished it.
    static func noteResult() { pending = true }

    /// Taken by the voice that speaks next (so a stopped or replaced line never counts).
    static func takePendingResult() -> Bool {
        defer { pending = false }
        return pending
    }

    /// A result was read aloud to the end. Counts it and asks right then if one is due.
    static func resultSpoken(viaVoiceOver: Bool) {
        let d = UserDefaults.standard
        let results = d.integer(forKey: countKey) + 1
        d.set(results, forKey: countKey)
        let now = Date()
        guard shouldAsk(results: results, launches: d.integer(forKey: launchesKey),
                        lastAskedAt: d.object(forKey: askedAtKey) as? Date,
                        resultsAtLastAsk: d.integer(forKey: countAtAskKey), now: now) else { return }
        d.set(now, forKey: askedAtKey)
        d.set(results, forKey: countAtAskKey)
        NSLog("RatePrompt: asking for a rating after success %d", results)
        // VoiceOver reads its own announcement (or focus) after the app's voice ends.
        let delay = viaVoiceOver || UIAccessibility.isVoiceOverRunning ? 2.5 : 0.7
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-rtcamRatePromptLog") {
                SpeakLog.note("ratePrompt", "requested after \(results)")
            }
            #endif
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
            AppStore.requestReview(in: scene)
        }
    }
}
