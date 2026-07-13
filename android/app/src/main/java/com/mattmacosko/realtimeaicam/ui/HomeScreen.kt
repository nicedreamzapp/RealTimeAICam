package com.mattmacosko.realtimeaicam.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mattmacosko.realtimeaicam.R
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.min

// Entry animation plays once per process (UI_SPEC §1.9)
private var homeIntroPlayed = false

@Composable
fun HomeScreen(
    versionLabel: String,
    voiceLabel: String,
    voiceEmoji: String,
    onEnglishOcr: () -> Unit,
    onSpanishOcr: () -> Unit,
    onObjectDetection: () -> Unit,
    onInfo: () -> Unit,
    onVoicePicker: () -> Unit,
) {
    val debouncer = rememberDebouncer(500)

    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        val screenWidth = maxWidth
        val scale = min(screenWidth.value / 390f, 1f)

        Image(
            painter = painterResource(R.drawable.splash_background),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
        )

        // Landscape: fixed spacing + scroll (weights are illegal in scrollables);
        // portrait: weighted spacers exactly like iOS.
        val isLandscape = maxWidth > maxHeight
        val columnModifier = if (isLandscape) {
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
        } else {
            Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp)
        }
        Column(
            modifier = columnModifier,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (isLandscape) Spacer(Modifier.height(16.dp))
            else Spacer(Modifier.weight(1f).height(80.dp))
            EntryAnimated(200) { HeadingPill(scale, screenWidth) }
            if (isLandscape) Spacer(Modifier.height(20.dp)) else Spacer(Modifier.weight(1f))

            Column(
                verticalArrangement = Arrangement.spacedBy((18 * scale).dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                EntryAnimated(700) {
                    ModeButton(IosColors.Blue, scale, screenWidth, onClick = {
                        if (debouncer.tryFire()) onEnglishOcr()
                    }) {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("📖", fontSize = (34 * scale).sp)
                            OutlinedText("Eng Text2Speech", (20 * scale).sp)
                            ShadedEmoji("🗣️", (29 * scale))
                        }
                    }
                }
                EntryAnimated(1200) {
                    ModeButton(IosColors.Green, scale, screenWidth, onClick = {
                        if (debouncer.tryFire()) onSpanishOcr()
                    }) {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(2.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("🇲🇽", fontSize = (31 * scale).sp)
                            OutlinedText("Span", (18 * scale).sp)
                            Text("🇺🇸", fontSize = (31 * scale).sp)
                            OutlinedText("Eng", (18 * scale).sp)
                            Text("🌎", fontSize = (31 * scale).sp)
                            OutlinedText("Translate", (18 * scale).sp)
                        }
                    }
                }
                EntryAnimated(1700) {
                    ModeButton(IosColors.Orange, scale, screenWidth, onClick = {
                        if (debouncer.tryFire()) onObjectDetection()
                    }) {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("🐶", fontSize = (35 * scale).sp)
                            OutlinedText("Object Detection", (20 * scale).sp)
                        }
                    }
                }
            }

            if (isLandscape) Spacer(Modifier.height(20.dp)) else Spacer(Modifier.weight(1f))
            EntryAnimated(2200) {
                VoicePickerPill(voiceEmoji, voiceLabel, scale, onVoicePicker)
            }
            Spacer(Modifier.height(if (isLandscape) 24.dp else 75.dp))
        }

        // Version label — bottom-left (spec §1.2), above the system nav bar
        Text(
            text = versionLabel,
            fontSize = 11.sp,
            color = IosColors.Secondary,
            modifier = Modifier
                .align(Alignment.BottomStart)
                .navigationBarsPadding()
                .padding(start = 14.dp, bottom = 10.dp),
        )

        // INFO 💡 GUIDE — top-end (spec §1.5)
        Box(
            Modifier
                .align(Alignment.TopEnd)
                .padding(top = 8.dp, end = 16.dp)
        ) {
            EntryAnimated(200) {
                InfoGuideButton(onClick = { if (debouncer.tryFire()) onInfo() })
            }
        }

        LaunchedEffect(Unit) {
            delay(2600)
            homeIntroPlayed = true
        }
    }
}

/** Fade 0→1 + scale 0.7→1, easeOut 300ms after [delayMs]; instant on revisit. */
@Composable
private fun EntryAnimated(delayMs: Long, content: @Composable () -> Unit) {
    val alpha = remember { Animatable(if (homeIntroPlayed) 1f else 0f) }
    val scaleAnim = remember { Animatable(if (homeIntroPlayed) 1f else 0.7f) }
    LaunchedEffect(Unit) {
        if (!homeIntroPlayed) {
            delay(delayMs)
            launch { alpha.animateTo(1f, tween(300, easing = FastOutSlowInEasing)) }
            scaleAnim.animateTo(1f, tween(300, easing = FastOutSlowInEasing))
        }
    }
    Box(Modifier.graphicsLayer {
        this.alpha = alpha.value
        scaleX = scaleAnim.value
        scaleY = scaleAnim.value
    }) { content() }
}

/** The big "RealTime / Ai Camera" layered glass pill (spec §1.3). */
@Composable
private fun HeadingPill(scale: Float, screenWidth: Dp) {
    Box(
        modifier = Modifier
            .width(screenWidth * 0.92f)
            .height((120 * scale).dp),
        contentAlignment = Alignment.Center,
    ) {
        // 1. Glow
        Box(
            Modifier
                .matchParentSize()
                .scale(1.12f)
                .blur((18 * scale).dp)
                .background(IosColors.Blue.copy(alpha = 0.35f), CapsuleShape)
        )
        // 2..6 main pill layers
        Box(
            Modifier
                .matchParentSize()
                .clip(CapsuleShape)
                .background(
                    Brush.horizontalGradient(
                        listOf(
                            Color.White.copy(alpha = 0.82f),
                            IosColors.Blue.copy(alpha = 0.55f),
                            Color.White.copy(alpha = 0.82f),
                        )
                    ),
                    CapsuleShape,
                )
                .border((4.2 * scale).dp, Color(0xFF3370D1).copy(alpha = 0.42f), CapsuleShape)
        ) {
            // Top gloss
            Box(
                Modifier
                    .fillMaxWidth()
                    .fillMaxHeight(0.48f)
                    .padding(top = 3.dp, start = 8.dp, end = 8.dp)
                    .blur(1.9.dp)
                    .background(
                        Brush.verticalGradient(
                            listOf(Color.White.copy(alpha = 0.62f), Color.Transparent)
                        ),
                        CapsuleShape,
                    )
            )
            // Inner stroke
            Box(
                Modifier
                    .matchParentSize()
                    .padding(1.9.dp)
                    .border(1.9.dp, Color.Black.copy(alpha = 0.16f), CapsuleShape)
            )
            // Inner glow
            Box(
                Modifier
                    .matchParentSize()
                    .padding(8.dp)
                    .blur(5.5.dp)
                    .background(Color.White.copy(alpha = 0.18f), CapsuleShape)
            )
            // Text
            Column(
                modifier = Modifier.align(Alignment.Center),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                OutlinedText(
                    "RealTime",
                    (52 * scale).sp,
                    fill = Color(0xFFA3D9FF),
                    strokeWidth = 2.1.dp,
                )
                OutlinedText(
                    "Ai Camera",
                    (44 * scale).sp,
                    fill = Color(0xFFCFEDFF),
                    strokeWidth = 2.1.dp,
                    modifier = Modifier.offset(y = (-8 * scale).dp),
                )
            }
        }
    }
}

/** The 5-layer glass capsule mode button (spec §1.4). */
@Composable
fun ModeButton(
    accent: Color,
    scale: Float,
    screenWidth: Dp,
    onClick: () -> Unit,
    content: @Composable () -> Unit,
) {
    val buttonWidth = minOf((340 * scale).dp, screenWidth - 36.dp)
    Box(contentAlignment = Alignment.Center) {
        // Colored outer glow (accent @ 50%, r12)
        Box(
            Modifier
                .matchParentSize()
                .blur(12.dp)
                .background(accent.copy(alpha = 0.5f), CapsuleShape)
        )
        Box(
            Modifier
                .width(buttonWidth)
                .shadow(8.dp, CapsuleShape, spotColor = Color.Black.copy(alpha = 0.38f))
                .clip(CapsuleShape)
                .background(
                    Brush.verticalGradient(
                        listOf(Color.White.copy(alpha = 0.23f), accent.copy(alpha = 0.50f))
                    ),
                    CapsuleShape,
                )
                .border(4.8.dp, Color.White.copy(alpha = 0.80f), CapsuleShape)
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onClick,
                ),
            contentAlignment = Alignment.Center,
        ) {
            // Accent inner stroke, inset inside the white stroke
            Box(
                Modifier
                    .matchParentSize()
                    .padding(2.4.dp)
                    .border(2.4.dp, accent, CapsuleShape)
            )
            // Gloss stripe near top
            Box(
                Modifier
                    .align(Alignment.TopCenter)
                    .fillMaxWidth(0.9f)
                    .height(24.dp)
                    .offset(y = 4.dp)
                    .background(Color.White.copy(alpha = 0.13f), CapsuleShape)
            )
            // Inner bottom shade
            Box(
                Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .height(24.dp)
                    .offset(y = 16.dp)
                    .blur(7.dp)
                    .background(Color.Black.copy(alpha = 0.12f), CapsuleShape)
            )
            Box(
                Modifier.padding(
                    vertical = (16 * scale).dp,
                    horizontal = (16 * scale).dp,
                )
            ) { content() }
        }
    }
}

/** White circle behind an emoji (spec §1.4 ShadedEmoji). */
@Composable
fun ShadedEmoji(emoji: String, sizeSp: Float) {
    val circle = (sizeSp * 1.35f).dp
    Box(contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .size(circle)
                .shadow(3.dp, CircleShape, spotColor = Color.Black.copy(alpha = 0.09f))
                .background(Color.White.copy(alpha = 0.92f), CircleShape)
        )
        Text(emoji, fontSize = sizeSp.sp)
    }
}

/** INFO 💡 GUIDE pill — mode-button recipe with black accent (spec §1.5). */
@Composable
private fun InfoGuideButton(onClick: () -> Unit) {
    val accent = Color.Black
    Box(
        Modifier
            .shadow(6.dp, CapsuleShape, spotColor = Color.Black.copy(alpha = 0.38f))
            .clip(CapsuleShape)
            .background(
                Brush.verticalGradient(
                    listOf(Color.White.copy(alpha = 0.23f), accent.copy(alpha = 0.50f))
                ),
                CapsuleShape,
            )
            .border(4.8.dp, Color.White.copy(alpha = 0.80f), CapsuleShape)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .matchParentSize()
                .padding(2.4.dp)
                .border(2.4.dp, accent, CapsuleShape)
        )
        Row(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(vertical = 6.dp, horizontal = 18.dp),
        ) {
            OutlinedText("INFO", 14.sp)
            Text("💡", fontSize = 14.sp)
            OutlinedText("GUIDE", 14.sp)
        }
    }
}

/** Collapsed voice-picker pill (spec §1.7). */
@Composable
private fun VoicePickerPill(
    emoji: String,
    label: String,
    scale: Float,
    onClick: () -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(CapsuleShape)
            .background(IosColors.Purple.copy(alpha = 0.24f), CapsuleShape)
            .border(1.1.dp, Color.Black, CapsuleShape)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            )
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Text(emoji, fontSize = (28 * scale).sp)
        Text(
            label,
            fontSize = (20 * scale).sp,
            fontWeight = FontWeight.Bold,
            color = Color.White,
        )
        Icon(
            Icons.Default.KeyboardArrowUp,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(18.dp),
        )
    }
}
