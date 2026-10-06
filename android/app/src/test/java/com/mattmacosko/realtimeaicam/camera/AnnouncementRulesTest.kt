package com.mattmacosko.realtimeaicam.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AnnouncementRulesTest {
    private fun seen(name: String, x: Float, y: Float, area: Float = 0.1f) =
        AnnouncementRules.Seen(name, x, y, area)

    @Test fun centreComesFirst() {
        val order = AnnouncementRules.centralFirst(listOf(
            seen("Trampoline", 0.1f, 0.1f),
            seen("Squash (Plant)", 0.52f, 0.48f),
            seen("Tree", 0.9f, 0.5f),
        ))
        assertEquals(listOf("Squash (Plant)", "Tree", "Trampoline"), order)
    }

    @Test fun tiesGoToTheBiggerBox() {
        val order = AnnouncementRules.centralFirst(listOf(
            seen("Cup", 0.5f, 0.5f, area = 0.01f),
            seen("Laptop", 0.5f, 0.5f, area = 0.3f),
        ))
        assertEquals(listOf("Laptop", "Cup"), order)
    }

    @Test fun eachNameOnce() {
        val order = AnnouncementRules.centralFirst(listOf(
            seen("Person", 0.5f, 0.5f), seen("Person", 0.2f, 0.2f),
        ))
        assertEquals(listOf("Person"), order)
    }

    @Test fun longerLinesWaitLonger() {
        assertTrue(AnnouncementRules.estimatedMs("cup, laptop, person") > AnnouncementRules.estimatedMs("cup"))
    }
}
