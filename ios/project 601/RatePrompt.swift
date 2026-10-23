import StoreKit
import UIKit

/// "Rate this app" (2026-10-23). RealTime AI Cam had 178 App Store downloads a month
/// and two ratings, because nothing ever asked. This asks through Apple's own
/// review sheet (SKStoreReviewController), which Apple shows at most three times a
/// year and which a person can switch off for every app in Settings.
///
/// When: only after the app has actually helped. Each spoken result counts (a
/// What's this description, an answer to a question, a translation, a read page).
/// After the 10th one, the next time the person comes back to the Home screen
/// (never mid-sentence, never on a camera screen) the sheet is requested once.
/// After that, at most once every 120 days and only after 30 more results.
/// Android does the same with Google Play's in-app review (RatePrompt.kt).
enum RatePrompt {
    static let firstAskAfter = 10
    static let moreResultsBeforeAskingAgain = 30
    static let daysBetweenAsks: Double = 120

    private static let countKey = "ratePrompt.results"
    private static let askedAtKey = "ratePrompt.lastAskedAt"
    private static let countAtAskKey = "ratePrompt.resultsAtLastAsk"

    /// A result was spoken to the person.
    static func noteResult() {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: countKey) + 1, forKey: countKey)
    }

    /// Pure rule, unit testable.
    static func shouldAsk(results: Int, lastAskedAt: Date?, resultsAtLastAsk: Int, now: Date) -> Bool {
        guard let last = lastAskedAt else { return results >= firstAskAfter }
        return now.timeIntervalSince(last) >= daysBetweenAsks * 86_400
            && results - resultsAtLastAsk >= moreResultsBeforeAskingAgain
    }

    /// Call when the Home screen comes back. Waits a moment so the screen reader
    /// finishes saying "Home" before Apple's sheet appears.
    @MainActor
    static func askIfDue() {
        let d = UserDefaults.standard
        let results = d.integer(forKey: countKey)
        let last = d.object(forKey: askedAtKey) as? Date
        guard shouldAsk(results: results, lastAskedAt: last,
                        resultsAtLastAsk: d.integer(forKey: countAtAskKey), now: Date()) else { return }
        d.set(Date(), forKey: askedAtKey)
        d.set(results, forKey: countAtAskKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
            SKStoreReviewController.requestReview(in: scene)
        }
    }
}
