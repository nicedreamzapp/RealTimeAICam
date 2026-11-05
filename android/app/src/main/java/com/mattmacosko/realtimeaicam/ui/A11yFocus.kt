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
        val root = view as? ViewRootForTest
        val node = root?.let { find(it.semanticsOwner.unmergedRootSemanticsNode, tag) }
        val provider = view.accessibilityNodeProvider
        if (node == null || provider == null) {
            log(view, "focus $tag: not found (root=${root != null} provider=${provider != null})")
            return false
        }
        var moved = provider.performAction(node.id, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null)
        if (!moved && provider.createAccessibilityNodeInfo(node.id)?.isAccessibilityFocused == true) {
            // TalkBack already put its focus there on its own, maybe before our cue: clear and
            // focus again so the control is said now, after the cue, and not just before it.
            provider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS, null)
            moved = provider.performAction(node.id, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null)
        }
        log(view, "focus $tag: node=${node.id} moved=$moved")
        return moved
    }

    /** [moveTo], tried a few times: the screen's accessibility tree can lag a frame or two behind. */
    suspend fun moveToSoon(view: View, tag: String, tries: Int = 4, gapMs: Long = 400L): Boolean {
        repeat(tries) { i ->
            if (moveTo(view, tag)) return true
            if (!UiCue.screenReaderOn(view.context)) return false
            if (i < tries - 1) delay(gapMs)
        }
        return false
    }

    private fun log(view: View, line: String) {
        if ((view.context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            android.util.Log.i("RTCamA11y", line)
        }
    }

    /**
     * Waits until this window has focus again (the camera permission dialog, for one, sits on
     * top at first launch); focus moved under a dialog would pull TalkBack off the dialog.
     */
    suspend fun awaitWindowFocus(view: View, timeoutMs: Long = 60_000L): Boolean {
        var waited = 0L
        while (!view.hasWindowFocus() && waited < timeoutMs) {
            delay(150)
            waited += 150
        }
        return view.hasWindowFocus()
    }

    private fun find(node: SemanticsNode, tag: String): SemanticsNode? {
        if (node.config.getOrNull(SemanticsProperties.TestTag) == tag) return node
        for (child in node.children) find(child, tag)?.let { return it }
        return null
    }
}
