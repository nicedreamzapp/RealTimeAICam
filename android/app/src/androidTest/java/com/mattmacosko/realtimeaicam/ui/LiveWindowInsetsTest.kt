package com.mattmacosko.realtimeaicam.ui

import android.view.View
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 11/04 review: every liveSafePadding added its own layout listener (~10 per camera screen).
 * Now one watcher per window root, shared, and gone when the last padded thing is.
 */
@RunWith(AndroidJUnit4::class)
class LiveWindowInsetsTest {
    @Test fun oneWatcherPerRootSharedAndRemovedWithTheLastUser() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val root = View(InstrumentationRegistry.getInstrumentation().targetContext)
            val before = LiveWindowInsets.count
            val watchers = (1..10).map { LiveWindowInsets.of(root) }
            watchers.forEach { assertSame(watchers[0], it) }
            watchers.forEach { it.acquire() }
            assertEquals(10, watchers[0].users)
            assertEquals(before + 1, LiveWindowInsets.count)
            watchers.forEach { it.release() }
            assertEquals(0, watchers[0].users)
            assertEquals(before, LiveWindowInsets.count)
            // An extra release never goes below zero.
            watchers[0].release()
            assertEquals(0, watchers[0].users)
        }
    }
}
