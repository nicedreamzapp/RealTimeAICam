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
            // The first padded thing acquires; every later one gets that same watcher.
            val firstOne = LiveWindowInsets.of(root).also { it.acquire() }
            assertEquals(before + 1, LiveWindowInsets.count)
            val watchers = listOf(firstOne) + (2..10).map { LiveWindowInsets.of(root).also { it.acquire() } }
            watchers.forEach { assertSame(firstOne, it) }
            assertEquals(10, watchers[0].users)
            assertEquals(before + 1, LiveWindowInsets.count)
            watchers.forEach { it.release() }
            assertEquals(0, watchers[0].users)
            assertEquals(before, LiveWindowInsets.count)
            // An extra release never goes below zero.
            watchers[0].release()
            assertEquals(0, watchers[0].users)
            // An old watcher released late never removes the one now in use.
            val now = LiveWindowInsets.of(root).also { it.acquire() }
            watchers[0].release()
            assertSame(now, LiveWindowInsets.of(root))
            now.release()
            assertEquals(before, LiveWindowInsets.count)
            // Never acquired: never kept.
            LiveWindowInsets.of(root)
            assertEquals(before, LiveWindowInsets.count)
        }
    }
}
