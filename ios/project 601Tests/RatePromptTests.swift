@testable import RealTime_Ai_Cam
import Foundation
import Testing

// Same cases as Android's RatePromptTest.kt.
struct RatePromptTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    @Test func neverAskedWaitsForTenResults() {
        #expect(!RatePrompt.shouldAsk(results: 9, lastAskedAt: nil, resultsAtLastAsk: 0, now: now))
        #expect(RatePrompt.shouldAsk(results: 10, lastAskedAt: nil, resultsAtLastAsk: 0, now: now))
    }

    @Test func askedRecentlyNeverAsksAgain() {
        #expect(!RatePrompt.shouldAsk(results: 500, lastAskedAt: daysAgo(30), resultsAtLastAsk: 10, now: now))
    }

    @Test func askedLongAgoNeedsThirtyMoreResults() {
        #expect(!RatePrompt.shouldAsk(results: 39, lastAskedAt: daysAgo(130), resultsAtLastAsk: 10, now: now))
        #expect(RatePrompt.shouldAsk(results: 40, lastAskedAt: daysAgo(130), resultsAtLastAsk: 10, now: now))
    }
}
