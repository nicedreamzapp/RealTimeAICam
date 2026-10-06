package com.mattmacosko.realtimeaicam.aim

import org.junit.Assert.assertEquals
import org.junit.Test

class AimRecentTest {
    @Test fun newestFirst() =
        assertEquals(listOf("laptop", "cup"), AimRecent.updated(listOf("cup"), "laptop"))

    @Test fun noDuplicatesIgnoringCase() =
        assertEquals(listOf("Cup", "laptop"), AimRecent.updated(listOf("laptop", "cup"), "Cup"))

    @Test fun keepsSix() {
        var list = emptyList<String>()
        for (w in listOf("a", "b", "c", "d", "e", "f", "g")) list = AimRecent.updated(list, w)
        assertEquals(listOf("g", "f", "e", "d", "c", "b"), list)
    }

    @Test fun blankIgnored() = assertEquals(listOf("cup"), AimRecent.updated(listOf("cup"), "  "))
}
