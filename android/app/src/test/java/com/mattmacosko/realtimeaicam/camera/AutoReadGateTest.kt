package com.mattmacosko.realtimeaicam.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AutoReadGateTest {

    private val page = "EXIT ONLY\nNo entry for pedestrians"
    private val jitter = "EXlT ONLY\nNo entry for pedestrlans"
    private val other = "Pharmacy open 9 to 5 Monday through Friday"

    @Test fun waitsUntilTextIsSteadyForOneSecond() {
        val g = AutoReadGate()
        g.observe(page, 0)
        assertNull(g.due(500, busy = false))
        g.observe(jitter, 700)                 // OCR flips a letter: still the same page
        assertEquals(jitter, g.due(1_000, busy = false))
    }

    @Test fun neverRepeatsTheSamePage() {
        val g = AutoReadGate()
        g.observe(page, 0)
        val line = g.due(1_000, busy = false)!!
        g.markSpoken(line, 1_000)
        for (t in 1_250L..20_000L step 700) {
            g.observe(if (t % 1400 == 0L) jitter else page, t)
            assertNull("repeated at $t", g.due(t, busy = false))
        }
    }

    @Test fun aPieceOfThePageAlreadyReadIsNotReadAgain() {
        val g = AutoReadGate()
        g.observe(page, 0)
        g.markSpoken(g.due(1_000, false)!!, 1_000)
        g.observe("No entry for pedestrians", 2_000) // top line slid out of the frame
        assertNull(g.due(4_000, busy = false))
    }

    @Test fun flickeringBetweenTwoPagesDoesNotChatter() {
        val g = AutoReadGate()
        // A new reading every 700 ms that keeps changing never settles, so nothing is read.
        for (i in 0 until 10) {
            val t = i * 700L
            g.observe(if (i % 2 == 0) page else other, t)
            assertNull(g.due(t, busy = false))
        }
    }

    @Test fun newPageWaitsForCurrentSpeechThenIsRead() {
        val g = AutoReadGate()
        g.observe(page, 0)
        g.markSpoken(g.due(1_000, false)!!, 1_000)
        g.observe(other, 1_500)
        assertNull(g.due(3_000, busy = true))   // still talking: never cut off
        assertEquals(other, g.due(3_250, busy = false))
    }

    @Test fun samePageReadAgainAfterTheCooldown() {
        val g = AutoReadGate(repeatWindowMs = 45_000)
        g.observe(page, 0)
        g.markSpoken(g.due(1_000, false)!!, 1_000)
        g.observe(page, 30_000)
        assertNull(g.due(31_000, false))
        g.observe(page, 47_000)
        assertEquals(page, g.due(47_000, false))
    }

    @Test fun resetForgetsWhatWasRead() {
        val g = AutoReadGate()
        g.observe(page, 0)
        g.markSpoken(g.due(1_000, false)!!, 1_000)
        g.reset()
        g.observe(page, 2_000)
        assertNull(g.due(2_500, false))
        assertEquals(page, g.due(3_000, false))
    }

    @Test fun tinyFragmentsAreIgnored() {
        val g = AutoReadGate()
        g.observe("a.", 0)
        assertNull(g.due(5_000, false))
    }

    @Test fun modesCycleInOrderAndParse() {
        assertEquals(ReadingMode.AUTO, ReadingMode.TAP.next)
        assertEquals(ReadingMode.MUTE, ReadingMode.AUTO.next)
        assertEquals(ReadingMode.TAP, ReadingMode.MUTE.next)
        assertEquals(ReadingMode.TAP, ReadingMode.fromKey(null))
        assertEquals(ReadingMode.MUTE, ReadingMode.fromKey("mute"))
    }
}
