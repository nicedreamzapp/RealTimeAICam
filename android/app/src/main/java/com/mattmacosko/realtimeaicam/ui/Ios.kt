package com.mattmacosko.realtimeaicam.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.absolutePadding
import androidx.compose.ui.composed
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.material3.Text
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import android.os.SystemClock

/** iOS dark-mode system colors — the app is always dark (UI_SPEC §0). */
object IosColors {
    val Blue = Color(0xFF0A84FF)
    val Green = Color(0xFF30D158)
    val Orange = Color(0xFFFF9F0A)
    val Red = Color(0xFFFF453A)
    val Yellow = Color(0xFFFFD60A)
    val Purple = Color(0xFFBF5AF2)
    val Cyan = Color(0xFF64D2FF)
    val Gray = Color(0xFF8E8E93)
    val Secondary = Color(0x99EBEBF5) // .secondary: #EBEBF5 @ 60%

    /** .ultraThinMaterial stand-in surfaces (spec §0). */
    val Material = Color(0xFF262626)
    val MaterialLight = Color(0xFF3A3A3C)
}

/** Fully-rounded capsule shape. */
val CapsuleShape = RoundedCornerShape(50)

/**
 * iOS OutlinedText (UI_SPEC §1.6): bold text drawn 5 times — 4 stroke-color
 * copies offset (±w, ±w) plus the fill copy on top.
 */
@Composable
fun OutlinedText(
    text: String,
    fontSize: TextUnit,
    modifier: Modifier = Modifier,
    fill: Color = Color.White,
    stroke: Color = Color.Black,
    strokeWidth: Dp = 1.1.dp,
    fontWeight: FontWeight = FontWeight.Bold,
) {
    val w = with(LocalDensity.current) { strokeWidth.toPx() }.let { kotlin.math.ceil(it).toInt() }
    // The outline is the same string drawn five times. Without collapsing the
    // semantics here, TalkBack reads every label on the home screen five times.
    Box(modifier.clearAndSetSemantics { contentDescription = text }) {
        for ((dx, dy) in listOf(-w to -w, w to -w, -w to w, w to w)) {
            Text(
                text = text,
                fontSize = fontSize,
                fontWeight = fontWeight,
                color = stroke,
                maxLines = 1,
                softWrap = false,
                modifier = Modifier.offset { IntOffset(dx, dy) },
            )
        }
        Text(
            text = text,
            fontSize = fontSize,
            fontWeight = fontWeight,
            color = fill,
            maxLines = 1,
            softWrap = false,
        )
    }
}

/** Simple tap debouncer (iOS debounces all mode buttons ~0.5s, Back 1.0s). */
class Debouncer(private val windowMs: Long = 500) {
    private var last = 0L
    fun tryFire(): Boolean {
        val now = SystemClock.elapsedRealtime()
        if (now - last < windowMs) return false
        last = now
        return true
    }
}

@Composable
fun rememberDebouncer(windowMs: Long = 500): Debouncer = remember { Debouncer(windowMs) }


/**
 * The words of a label without its emoji, for screen readers. TalkBack reads
 * an emoji by name ("dog Object Detection"), which a blind tester asked us to
 * stop on 2026-09-25: the pictures stay on screen, the names are spoken plain.
 */
private val emojiPattern = Regex("[\\x{1F000}-\\x{1FAFF}\\x{2190}-\\x{21FF}\\x{2300}-\\x{23FF}\\x{2600}-\\x{27BF}\\x{2B00}-\\x{2BFF}\\x{2139}\\x{FE0F}\\x{200D}\\x{20E3}]")

fun String.withoutEmoji(): String =
    replace(emojiPattern, "").replace(Regex("^[•\\s]+"), "").replace(Regex("\\s{2,}"), " ").trim()

/**
 * Padding for the system bars and the display cutout, read from the window itself on every
 * layout instead of from Compose's WindowInsets.
 *
 * 2026-11-04, the Cricket (Android 13): after a rotation Compose kept the portrait insets
 * (status bar on top, nothing at the side), so in landscape Object Detection the "Volume is
 * off" banner and the Back pill sat under the navigation bar. The window's own insets are
 * always the current ones, so every camera screen pads with these.
 *
 * [horizontal] pads left and right, [top] and [bottom] those edges. [navOnly] counts only
 * the navigation bar (what navigationBarsPadding() did); otherwise status bar, navigation
 * bar and cutout together (what safeDrawing did, minus the keyboard).
 */
fun Modifier.liveSafePadding(
    horizontal: Boolean = false,
    top: Boolean = false,
    bottom: Boolean = false,
    navOnly: Boolean = false,
): Modifier = composed {
    val view = androidx.compose.ui.platform.LocalView.current
    val configuration = androidx.compose.ui.platform.LocalConfiguration.current
    val density = LocalDensity.current
    val types = if (navOnly) androidx.core.view.WindowInsetsCompat.Type.navigationBars()
    else androidx.core.view.WindowInsetsCompat.Type.systemBars() or androidx.core.view.WindowInsetsCompat.Type.displayCutout()
    var insets by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(androidx.core.graphics.Insets.NONE) }
    androidx.compose.runtime.DisposableEffect(view, types, configuration) {
        val root = view.rootView
        fun read() {
            val now = androidx.core.view.ViewCompat.getRootWindowInsets(root)?.getInsets(types) ?: return
            if (now != insets) insets = now
        }
        val listener = android.view.ViewTreeObserver.OnGlobalLayoutListener { read() }
        root.viewTreeObserver.addOnGlobalLayoutListener(listener)
        read()
        // A 180° turn (landscape to seascape) changes no size; look again once it settles.
        val late = Runnable { read() }
        root.postDelayed(late, 400)
        onDispose {
            root.removeCallbacks(late)
            if (root.viewTreeObserver.isAlive) root.viewTreeObserver.removeOnGlobalLayoutListener(listener)
        }
    }
    with(density) {
        Modifier.absolutePadding(
            left = if (horizontal) insets.left.toDp() else 0.dp,
            top = if (top) insets.top.toDp() else 0.dp,
            right = if (horizontal) insets.right.toDp() else 0.dp,
            bottom = if (bottom) insets.bottom.toDp() else 0.dp,
        )
    }
}
