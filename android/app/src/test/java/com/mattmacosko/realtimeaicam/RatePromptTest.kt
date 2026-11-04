package com.mattmacosko.realtimeaicam

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Same cases as iOS RatePromptTests.swift (rule of 2026-11-04). */
class RatePromptTest {
    private val now = 2_000_000_000_000L
    private fun daysAgo(d: Long) = now - d * 86_400_000L

    @Test fun neverAskedWaitsForTheThirdSuccess() {
        assertFalse(RatePrompt.shouldAsk(results = 1, launches = 5, lastAskedAtMs = 0L, resultsAtLastAsk = 0, nowMs = now))
        assertFalse(RatePrompt.shouldAsk(2, 5, 0L, 0, now))
        assertTrue(RatePrompt.shouldAsk(3, 5, 0L, 0, now))
        assertTrue(RatePrompt.shouldAsk(7, 5, 0L, 0, now))
    }

    @Test fun neverOnTheFirstLaunch() {
        assertFalse(RatePrompt.shouldAsk(50, 1, 0L, 0, now))
        assertFalse(RatePrompt.shouldAsk(50, 0, 0L, 0, now))
        assertTrue(RatePrompt.shouldAsk(3, 2, 0L, 0, now))
    }

    @Test fun atMostOnceEverySixtyDays() {
        assertFalse(RatePrompt.shouldAsk(500, 9, daysAgo(1), 3, now))
        assertFalse(RatePrompt.shouldAsk(500, 9, daysAgo(59), 3, now))
        assertTrue(RatePrompt.shouldAsk(500, 9, daysAgo(60), 3, now))
    }

    @Test fun askingAgainNeedsThreeMoreSuccesses() {
        assertFalse(RatePrompt.shouldAsk(5, 9, daysAgo(90), 3, now))
        assertTrue(RatePrompt.shouldAsk(6, 9, daysAgo(90), 3, now))
    }

    @Test fun ruleConstantsMatchTheBrief() {
        assertTrue(RatePrompt.FIRST_ASK_AFTER == 3 && RatePrompt.DAYS_BETWEEN_ASKS == 60L && RatePrompt.MIN_LAUNCHES == 2)
    }
}
