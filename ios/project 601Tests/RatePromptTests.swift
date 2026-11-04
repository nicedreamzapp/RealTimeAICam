@testable import RealTime_Ai_Cam
import Foundation
import Testing

// Same cases as Android's RatePromptTest.kt (store brief 2026-11-04).
struct RatePromptTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    @Test func neverAskedWaitsForTheThirdSuccess() {
        #expect(!RatePrompt.shouldAsk(results: 1, launches: 5, lastAskedAt: nil, resultsAtLastAsk: 0, now: now))
        #expect(!RatePrompt.shouldAsk(results: 2, launches: 5, lastAskedAt: nil, resultsAtLastAsk: 0, now: now))
        #expect(RatePrompt.shouldAsk(results: 3, launches: 5, lastAskedAt: nil, resultsAtLastAsk: 0, now: now))
        #expect(RatePrompt.shouldAsk(results: 7, launches: 5, lastAskedAt: nil, resultsAtLastAsk: 0, now: now))
    }

    @Test func neverOnTheFirstLaunch() {
        #expect(!RatePrompt.shouldAsk(results: 50, launches: 1, lastAskedAt: nil, resultsAtLastAsk: 0, now: now))
        #expect(!RatePrompt.shouldAsk(results: 50, launches: 0, lastAskedAt: nil, resultsAtLastAsk: 0, now: now))
        #expect(RatePrompt.shouldAsk(results: 3, launches: 2, lastAskedAt: nil, resultsAtLastAsk: 0, now: now))
    }

    @Test func atMostOnceEverySixtyDays() {
        #expect(!RatePrompt.shouldAsk(results: 500, launches: 9, lastAskedAt: daysAgo(1), resultsAtLastAsk: 3, now: now))
        #expect(!RatePrompt.shouldAsk(results: 500, launches: 9, lastAskedAt: daysAgo(59), resultsAtLastAsk: 3, now: now))
        #expect(RatePrompt.shouldAsk(results: 500, launches: 9, lastAskedAt: daysAgo(60), resultsAtLastAsk: 3, now: now))
    }

    @Test func askingAgainNeedsThreeMoreSuccesses() {
        #expect(!RatePrompt.shouldAsk(results: 5, launches: 9, lastAskedAt: daysAgo(90), resultsAtLastAsk: 3, now: now))
        #expect(RatePrompt.shouldAsk(results: 6, launches: 9, lastAskedAt: daysAgo(90), resultsAtLastAsk: 3, now: now))
    }

    @Test func ruleConstantsMatchTheBrief() {
        #expect(RatePrompt.firstAskAfter == 3 && RatePrompt.daysBetweenAsks == 60 && RatePrompt.minLaunches == 2)
    }

    @Test func onlyTheNextSpokenLineCountsAndOnlyOnce() {
        _ = RatePrompt.takePendingResult()
        #expect(!RatePrompt.takePendingResult())
        RatePrompt.noteResult()
        #expect(RatePrompt.takePendingResult())
        #expect(!RatePrompt.takePendingResult())
    }
}
