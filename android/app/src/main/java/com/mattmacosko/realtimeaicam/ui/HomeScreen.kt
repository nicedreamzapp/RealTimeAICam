package com.mattmacosko.realtimeaicam.ui

import androidx.compose.ui.res.stringResource
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
import androidx.compose.ui.semantics.heading
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.WindowInsets
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mattmacosko.realtimeaicam.R
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.max
import kotlin.math.min

// Entry animation plays once per process (UI_SPEC §1.9)
private var homeIntroPlayed = false

@Composable
fun HomeScreen(
    versionLabel: String,
    voiceLabel: String,
    voiceEmoji: String,
    onRead: () -> Unit,
    onObjectDetection: () -> Unit,
    onWhatsThis: () -> Unit,
    onHelpMeAim: () -> Unit,
    onLiveCam: () -> Unit,
    onSettings: () -> Unit,
    onInfo: () -> Unit,
    onVoicePicker: () -> Unit,
) {
    val debouncer = rememberDebouncer(500)

    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        val screenWidth = maxWidth
        val screenHeight = maxHeight
        val scale = min(screenWidth.value / 390f, 1f)

        Image(
            painter = painterResource(R.drawable.splash_background),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
        )

        // iOS parity (2026-11-03/04): centered top row (Settings, Info), the title, five
        // equal full-tap buttons with real gaps, then the voice. Natural spacing that can
        // never overlap: when it doesn't fit (small phones, landscape) the page scrolls
        // instead of squeezing. TalkBack order is top to bottom.
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .heightIn(min = screenHeight)
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 16.dp)
                .padding(top = 14.dp, bottom = 36.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            EntryAnimated(200) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    SettingsPill(onClick = { if (debouncer.tryFire()) onSettings() })
                    InfoGuideButton(onClick = { if (debouncer.tryFire()) onInfo() })
                }
            }
            Spacer(Modifier.height((28 * scale).dp))
            EntryAnimated(200) { HeadingPill(scale, screenWidth) }
            Spacer(Modifier.height((24 * scale).dp))

            Column(
                verticalArrangement = Arrangement.spacedBy(max(14f, 22 * scale).dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                EntryAnimated(700) {
                    ModeButton(
                        IosColors.Blue, scale, screenWidth,
                        onClick = { if (debouncer.tryFire()) onRead() },
                        label = stringResource(R.string.e_home_read),
                        clickLabel = stringResource(R.string.e_home_read_action),
                    ) {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("📖", fontSize = (32 * scale).sp)
                            OutlinedText(stringResource(R.string.e_home_read), (20 * scale).sp)
                            Text("🌍", fontSize = (26 * scale).sp)
                        }
                    }
                }
                EntryAnimated(1200) {
                    ModeButton(
                        IosColors.Orange, scale, screenWidth,
                        onClick = { if (debouncer.tryFire()) onObjectDetection() },
                        label = stringResource(R.string.e_home_object_detection),
                        clickLabel = stringResource(R.string.e_home_od_action),
                    ) {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("🐶", fontSize = (32 * scale).sp)
                            OutlinedText(stringResource(R.string.e_home_object_detection), (20 * scale).sp)
                        }
                    }
                }
                EntryAnimated(1700) {
                    ModeButton(
                        IosColors.Purple, scale, screenWidth,
                        onClick = { if (debouncer.tryFire()) onWhatsThis() },
                        label = stringResource(R.string.e_home_whats_this),
                        clickLabel = stringResource(R.string.e_home_wt_action),
                    ) {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("\uD83D\uDCC4", fontSize = (32 * scale).sp)
                            OutlinedText(stringResource(R.string.e_home_whats_this), (20 * scale).sp)
                        }
                    }
                }
                // Help Me Aim: its own button, exactly as on the iPhone. What's
                // this? answers a question and throws the photo away; this one
                // talks you into the shot and keeps it.
                EntryAnimated(2200) {
                    ModeButton(
                        HomeTeal, scale, screenWidth,
                        onClick = { if (debouncer.tryFire()) onHelpMeAim() },
                        label = stringResource(R.string.e_home_help_me_aim),
                        clickLabel = stringResource(R.string.e_home_aim_action),
                    ) {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("\uD83C\uDFAF", fontSize = (32 * scale).sp)
                            OutlinedText(stringResource(R.string.e_home_help_me_aim), (20 * scale).sp)
                        }
                    }
                }
                // Live Cam: layout only for now (iOS 6e1fc97); the tap says it is coming soon.
                EntryAnimated(2700) {
                    ModeButton(
                        HomePink, scale, screenWidth,
                        onClick = { if (debouncer.tryFire()) onLiveCam() },
                        label = stringResource(R.string.e_home_live_cam_label),
                        clickLabel = stringResource(R.string.e_home_live_action),
                    ) {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("\uD83D\uDCAC", fontSize = (32 * scale).sp)
                            OutlinedText("Live Cam", (20 * scale).sp)
                            // Experimental (Matt, 2026-11-04): a small tag inside the button, so the
                            // button keeps the same height as the other four.
                            Text(
                                stringResource(R.string.e_experimental),
                                fontSize = (11 * scale).coerceAtLeast(9f).sp,
                                fontWeight = FontWeight.SemiBold,
                                color = Color.White,
                                maxLines = 1,
                                softWrap = false,
                                modifier = Modifier
                                    .padding(start = 4.dp)
                                    .clip(CapsuleShape)
                                    .background(Color.Black.copy(alpha = 0.35f), CapsuleShape)
                                    .border(1.dp, Color.White.copy(alpha = 0.7f), CapsuleShape)
                                    .padding(horizontal = 6.dp, vertical = 2.dp),
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height((28 * scale).dp))
            EntryAnimated(3200) {
                VoicePickerPill(voiceEmoji, voiceLabel, scale, onVoicePicker)
            }
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

        LaunchedEffect(Unit) {
            delay(3500)
            homeIntroPlayed = true
        }
    }
}

private val HomeTeal = Color(0xFF40C8E0)
private val HomePink = Color(0xFFFF375F)

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
            .width(minOf(screenWidth * 0.92f, 440.dp))
            .height((120 * scale).dp)
            .clearAndSetSemantics {
                contentDescription = "RealTime AI Camera"
                heading()
            },
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
    label: String = "",
    clickLabel: String? = null,
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
                // Every tool the same size, whatever its emoji (iOS parity 2026-11-03).
                .height(max(56f, 68 * scale).dp)
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
                    role = Role.Button,
                    onClickLabel = clickLabel,
                    onClick = onClick,
                )
                // Only the words: the emoji drawn inside would be read by name.
                .clearAndSetSemantics {
                    if (label.isNotEmpty()) contentDescription = label
                },
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
            Box(Modifier.padding(horizontal = (16 * scale).dp)) { content() }
        }
    }
}

/** White circle behind an emoji (spec §1.4 ShadedEmoji). */
@Composable
fun ShadedEmoji(emoji: String, sizeSp: Float) {
    val circle = (sizeSp * 1.35f).dp
    // Decorative — the containing control carries the real label.
    Box(
        modifier = Modifier.clearAndSetSemantics { },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .size(circle)
                .shadow(3.dp, CircleShape, spotColor = Color.Black.copy(alpha = 0.09f))
                .background(Color.White.copy(alpha = 0.92f), CircleShape)
        )
        Text(emoji, fontSize = sizeSp.sp)
    }
}

/** SETTINGS ⚙️ pill next to INFO (iOS parity 2026-11-03): Models etc. right from home. */
@Composable
private fun SettingsPill(onClick: () -> Unit) {
    val accent = Color.Black
    val settingsLabel = stringResource(R.string.e_home_settings_label)
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
                role = Role.Button,
                onClickLabel = stringResource(R.string.e_home_settings_action),
                onClick = onClick,
            )
            .clearAndSetSemantics {
                contentDescription = settingsLabel
                // TalkBack lands here when the guide closes (MainScreen).
                testTag = HOME_FIRST_CONTROL_TAG
            },
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
            modifier = Modifier.padding(vertical = 12.dp, horizontal = 14.dp),
        ) {
            Text("⚙️", fontSize = 14.sp)
            OutlinedText(stringResource(R.string.e_home_settings_word), 14.sp)
        }
    }
}

/** INFO 💡 GUIDE pill — mode-button recipe with black accent (spec §1.5). */
@Composable
private fun InfoGuideButton(onClick: () -> Unit) {
    val accent = Color.Black
    val infoLabel = stringResource(R.string.e_home_info_label)
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
                role = Role.Button,
                onClickLabel = stringResource(R.string.e_home_info_action),
                onClick = onClick,
            )
            .clearAndSetSemantics { contentDescription = infoLabel },
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
            modifier = Modifier.padding(vertical = 12.dp, horizontal = 18.dp),
        ) {
            OutlinedText(stringResource(R.string.e_home_info_word), 14.sp)
            Text("💡", fontSize = 14.sp)
            OutlinedText(stringResource(R.string.e_home_guide_word), 14.sp)
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
    val voiceLabel = stringResource(R.string.e_home_voice_label, label)
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
                role = Role.Button,
                onClickLabel = stringResource(R.string.e_home_voice_action),
                onClick = onClick,
            )
            .padding(horizontal = 12.dp, vertical = 6.dp)
            .clearAndSetSemantics { contentDescription = voiceLabel },
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
