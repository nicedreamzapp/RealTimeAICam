package com.mattmacosko.realtimeaicam

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Same cases as iOS RatePromptTests.swift. */
class RatePromptTest {
    private val now = 2_000_000_000_000L
    private fun daysAgo(d: Long) = now - d * 86_400_000L

    @Test fun neverAskedWaitsForTenResults() {
        assertFalse(RatePrompt.shouldAsk(9, 0L, 0, now))
        assertTrue(RatePrompt.shouldAsk(10, 0L, 0, now))
    }

    @Test fun askedRecentlyNeverAsksAgain() {
        assertFalse(RatePrompt.shouldAsk(500, daysAgo(30), 10, now))
    }

    @Test fun askedLongAgoNeedsThirtyMoreResults() {
        assertFalse(RatePrompt.shouldAsk(39, daysAgo(130), 10, now))
        assertTrue(RatePrompt.shouldAsk(40, daysAgo(130), 10, now))
    }
}
