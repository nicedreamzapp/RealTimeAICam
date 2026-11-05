package com.mattmacosko.realtimeaicam.ui

import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import com.mattmacosko.realtimeaicam.camera.UiCue
import kotlinx.coroutines.delay

/**
 * Moves TalkBack's focus to a control by its test tag (2026-11-04, first-time-user test: after
 * Done on the guide, focus was left on nothing and the home screen came back in silence).
 * TalkBack says the control it lands on. Does nothing when TalkBack is off.
 */
object A11yFocus {
    fun moveTo(view: View, tag: String): Boolean {
        if (!UiCue.screenReaderOn(view.context)) return false
        val root = view as? ViewRootForTest ?: return false
        val node = find(root.semanticsOwner.unmergedRootSemanticsNode, tag) ?: return false
        val provider = view.accessibilityNodeProvider ?: return false
        return provider.performAction(node.id, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null)
    }

    /**
     * Waits until this window has focus again (the camera permission dialog, for one, sits on
     * top at first launch); focus moved under a dialog would pull TalkBack off the dialog.
     */
    suspend fun awaitWindowFocus(view: View, timeoutMs: Long = 60_000L) {
        var waited = 0L
        while (!view.hasWindowFocus() && waited < timeoutMs) {
            delay(150)
            waited += 150
        }
    }

    private fun find(node: SemanticsNode, tag: String): SemanticsNode? {
        if (node.config.getOrNull(SemanticsProperties.TestTag) == tag) return node
        for (child in node.children) find(child, tag)?.let { return it }
        return null
    }
}
