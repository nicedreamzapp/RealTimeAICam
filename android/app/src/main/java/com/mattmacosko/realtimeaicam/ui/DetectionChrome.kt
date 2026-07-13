package com.mattmacosko.realtimeaicam.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cameraswitch
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.Widgets
import androidx.compose.material.icons.filled.FlashlightOff
import androidx.compose.material.icons.filled.FlashlightOn
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mattmacosko.realtimeaicam.camera.DetectionPipeline
import com.mattmacosko.realtimeaicam.camera.DetectionUiState
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

/**
 * iOS Object Detection chrome (UI_SPEC §2): Back pill, FPS + count chips,
 * zoom pill, segmented category filter, 6-button control row + popups.
 */
@Composable
fun DetectionChrome(
    state: DetectionUiState,
    pipeline: DetectionPipeline,
    onBack: () -> Unit,
) {
    val torchOn by pipeline.torchOn.collectAsState()
    val zoom by pipeline.zoomRatio.collectAsState()
    val confidence by pipeline.confidenceThreshold.collectAsState()
    val isFront by pipeline.isFrontCamera.collectAsState()
    val hasUltraWide by pipeline.hasUltraWide.collectAsState()
    val isUltraWide by pipeline.isUltraWide.collectAsState()
    val speechEnabled by pipeline.announcer.enabled.collectAsState()

    val filterMode by pipeline.filterMode.collectAsState()
    val filterIndex = when (filterMode) { "indoor" -> 1; "outdoor" -> 2; else -> 0 }
    var showTorchPopup by remember { mutableStateOf(false) }
    var showConfidencePopup by remember { mutableStateOf(false) }
    var torchPreset by remember { mutableStateOf(100) }
    val buttonDebouncer = rememberDebouncer(500)

    // Torch popup dismisses on rotation instead of floating mid-screen
    val orientation = androidx.compose.ui.platform.LocalConfiguration.current.orientation
    val isLandscape =
        orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
    LaunchedEffect(orientation) { showTorchPopup = false }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val fullWidth = maxWidth
        // ---- Top row (spec §2.1) ----
        // Landscape: chrome hugs the top edge (minimal padding past the
        // safe/cutout inset) to maximize visible camera area.
        Row(
            Modifier
                .fillMaxWidth()
                .windowInsetsPadding(
                    if (isLandscape) {
                        WindowInsets.safeDrawing.only(
                            WindowInsetsSides.Horizontal + WindowInsetsSides.Top
                        )
                    } else {
                        WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)
                    }
                )
                .padding(
                    top = if (isLandscape) 4.dp else 50.dp,
                    start = if (isLandscape) 16.dp else 28.dp,
                    end = if (isLandscape) 16.dp else 36.dp,
                ),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.Top,
        ) {
            BackPill(onBack)
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FpsChip(state.fps)
                if (state.detections.isNotEmpty()) {
                    CountChip(state.detections.size)
                }
            }
        }

        // ---- Zoom pill (spec §2.2) ----
        AnimatedVisibility(
            visible = zoom < 0.95f || zoom > 1.05f,
            enter = fadeIn(tween(200)),
            exit = fadeOut(tween(200)),
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = 60.dp),
        ) {
            Text(
                "%.1fx".format(zoom),
                fontSize = 18.sp,
                fontWeight = FontWeight.Medium,
                color = Color.White,
                modifier = Modifier
                    .clip(CapsuleShape)
                    .background(Color.Black.copy(alpha = 0.70f), CapsuleShape)
                    .padding(horizontal = 12.dp, vertical = 6.dp),
            )
        }

        // ---- Bottom controls (spec §2.4) ----
        // FIXED anchor: the control column/row is its own root child; popups
        // are separate floating layers below so the row NEVER shifts on press.
        // The six buttons are one content lambda shared by both orientations.
        val controlButtons: @Composable () -> Unit = {
            // 1. Camera flip — iOS handleFlipCamera (front ↔ rear)
            CircleControlButton(onClick = {
                if (buttonDebouncer.tryFire()) pipeline.flipCamera()
            }) {
                Icon(Icons.Default.Cameraswitch, null, tint = Color.White, modifier = Modifier.size(22.dp))
            }
            // 2. Lens toggle — iOS handleToggleCameraZoom (ultra-wide).
            //    Hidden (slot preserved) when unsupported or front camera,
            //    exactly like iOS's opacity-0 + disabled treatment.
            Box(Modifier.alpha(if (hasUltraWide && !isFront) 1f else 0f)) {
                CircleControlButton(onClick = {
                    if (hasUltraWide && !isFront && buttonDebouncer.tryFire()) {
                        pipeline.toggleUltraWide()
                    }
                }) {
                    Icon(
                        Icons.Default.Widgets,
                        null,
                        tint = if (isUltraWide) IosColors.Cyan else Color.White,
                        modifier = Modifier.size(22.dp),
                    )
                }
            }
            // 3. Torch — hidden when front camera (no flash), like iOS
            Box(Modifier.alpha(if (isFront) 0f else 1f)) {
                CircleControlButton(
                    ringColor = if (torchOn) IosColors.Yellow.copy(alpha = 0.5f) else Color.White.copy(alpha = 0.2f),
                    onClick = {
                        if (isFront) return@CircleControlButton
                        if (torchOn) pipeline.setTorch(false)
                        else showTorchPopup = !showTorchPopup
                    },
                ) {
                    Icon(
                        if (torchOn) Icons.Default.FlashlightOn else Icons.Default.FlashlightOff,
                        null,
                        tint = if (torchOn) IosColors.Yellow else Color.White,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
            // 4. LiDAR — no Android equivalent: alpha 0, slot preserved (spec §7.1)
            Box(Modifier.alpha(0f)) {
                CircleControlButton(onClick = {}) {
                    Icon(Icons.Default.Straighten, null, tint = IosColors.Blue, modifier = Modifier.size(22.dp))
                }
            }
            // 5. Speech toggle — iOS handleToggleSpeech
            CircleControlButton(
                ringColor = if (speechEnabled) IosColors.Green.copy(alpha = 0.5f) else Color.White.copy(alpha = 0.25f),
                ringWidth = if (speechEnabled) 2.dp else 1.dp,
                onClick = {
                    if (!buttonDebouncer.tryFire()) return@CircleControlButton
                    pipeline.announcer.setEnabled(!speechEnabled)
                },
            ) {
                Text("🗣️", fontSize = 20.sp)
            }
            // 6. Confidence
            CircleControlButton(onClick = { showConfidencePopup = !showConfidencePopup }) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Icon(Icons.Default.Visibility, null, tint = Color.White, modifier = Modifier.size(16.dp))
                    Text(
                        "${(confidence * 100).roundToInt()}%",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color.White,
                        maxLines = 1,
                        softWrap = false,
                    )
                }
            }
        }

        val segmentedOnSelect: (Int) -> Unit = {
            pipeline.filterMode.value = when (it) {
                1 -> "indoor"; 2 -> "outdoor"; else -> "all"
            }
        }

        // Landscape single-row geometry (iOS landscapeOverlays: 6 buttons then
        // a 200pt segmented picker, 12pt spacing, one condensed row):
        // 6×44 buttons + 6×12 gaps + 200 segmented = 536dp, centered.
        val landRowWidth = 536.dp
        val landRowStart = (fullWidth - landRowWidth) / 2

        if (isLandscape) {
            // NOTE: bottom-only navbar inset. In landscape the 3-button navbar
            // is a SIDE inset; full navigationBarsPadding() would push the row
            // off display-center and break the popup anchor math below.
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .windowInsetsPadding(
                        WindowInsets.navigationBars.only(WindowInsetsSides.Bottom)
                    )
                    .padding(bottom = 10.dp),
            ) {
                controlButtons()
                IosSegmentedControl(
                    options = listOf("All", "Indoor", "Outdoor"),
                    selectedIndex = filterIndex,
                    onSelect = segmentedOnSelect,
                    modifier = Modifier.width(200.dp),
                )
            }
        } else {
            Column(
                verticalArrangement = Arrangement.spacedBy(12.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .windowInsetsPadding(
                        WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)
                    )
                    .navigationBarsPadding()
                    .padding(bottom = 32.dp),
            ) {
                IosSegmentedControl(
                    options = listOf("All", "Indoor", "Outdoor"),
                    selectedIndex = filterIndex,
                    onSelect = segmentedOnSelect,
                    modifier = Modifier.width(minOf(fullWidth - 32.dp, 560.dp)),
                )
                Row(
                    horizontalArrangement = Arrangement.SpaceEvenly,
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp),
                ) {
                    controlButtons()
                }
            }
        }

            // Tap anywhere outside the torch popup to dismiss it
            if (showTorchPopup && !torchOn) {
                Box(
                    Modifier
                        .fillMaxSize()
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                        ) { showTorchPopup = false }
                )
            }

            // ---- Torch preset popup (spec §2.6), above button 3 of 6 ----
            AnimatedVisibility(
                visible = showTorchPopup && !torchOn,
                enter = scaleIn(initialScale = 0.95f, animationSpec = tween(100)) + fadeIn(tween(100)),
                exit = scaleOut(targetScale = 0.95f, animationSpec = tween(100)) + fadeOut(tween(100)),
                modifier = if (isLandscape) {
                    Modifier
                        .align(Alignment.BottomStart)
                        .windowInsetsPadding(
                            WindowInsets.navigationBars.only(WindowInsetsSides.Bottom)
                        )
                        .padding(bottom = 66.dp) // floats above the FIXED single row
                        // torch = button 3 of the 536dp row: center 134dp in
                        .offset(x = landRowStart + 134.dp - 34.dp)
                } else {
                    Modifier
                        .align(Alignment.BottomStart)
                        .navigationBarsPadding()
                        .padding(bottom = 162.dp) // floats above the FIXED control row
                        .offset(x = fullWidth * (2.5f / 6f) - 34.dp)
                },
            ) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .clip(RoundedCornerShape(12.dp))
                        .background(IosColors.Material.copy(alpha = 0.80f), RoundedCornerShape(12.dp))
                        .border(1.dp, Color.White.copy(alpha = 0.2f), RoundedCornerShape(12.dp))
                        .padding(vertical = 8.dp, horizontal = 4.dp),
                ) {
                    for (preset in listOf(100, 75, 50, 25)) {
                        val selected = preset == torchPreset
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .size(width = 60.dp, height = 36.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .background(
                                    if (selected) IosColors.Yellow.copy(alpha = 0.4f)
                                    else Color.White.copy(alpha = 0.2f),
                                    RoundedCornerShape(8.dp),
                                )
                                .border(
                                    1.dp,
                                    if (selected) IosColors.Yellow else Color.White.copy(alpha = 0.3f),
                                    RoundedCornerShape(8.dp),
                                )
                                .clickable {
                                    torchPreset = preset
                                    pipeline.setTorch(true)
                                    showTorchPopup = false
                                },
                        ) {
                            Text("$preset%", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Color.White)
                        }
                    }
                }
            }

            // ---- Confidence slider popup (spec §2.5), above button 6 of 6 ----
            AnimatedVisibility(
                visible = showConfidencePopup,
                enter = scaleIn(initialScale = 0.9f) + fadeIn(),
                exit = scaleOut(targetScale = 0.9f) + fadeOut(),
                modifier = if (isLandscape) {
                    Modifier
                        .align(Alignment.BottomStart)
                        .windowInsetsPadding(
                            WindowInsets.navigationBars.only(WindowInsetsSides.Bottom)
                        )
                        .padding(bottom = 66.dp) // floats above the FIXED single row
                        // confidence = button 6 of the 536dp row: center 302dp in
                        .offset(x = landRowStart + 302.dp - 32.dp)
                } else {
                    Modifier
                        .align(Alignment.BottomEnd)
                        .navigationBarsPadding()
                        .padding(bottom = 132.dp, end = 14.dp) // floats above the FIXED row
                },
            ) {
                var dragging by remember { mutableStateOf(false) }
                LaunchedEffect(dragging, showConfidencePopup) {
                    if (!dragging && showConfidencePopup) {
                        delay(2500)
                        showConfidencePopup = false
                    }
                }
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier
                        .clip(RoundedCornerShape(16.dp))
                        .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(16.dp))
                        .padding(10.dp),
                ) {
                    Box(Modifier.size(width = 44.dp, height = 170.dp), contentAlignment = Alignment.Center) {
                        Slider(
                            value = confidence,
                            onValueChange = {
                                dragging = true
                                pipeline.confidenceThreshold.value = it.coerceIn(0.0001f, 1f)
                            },
                            onValueChangeFinished = { dragging = false },
                            valueRange = 0.0001f..1f,
                            colors = SliderDefaults.colors(
                                thumbColor = Color.White,
                                activeTrackColor = IosColors.Blue,
                                inactiveTrackColor = Color(0xFF787880).copy(alpha = 0.32f),
                            ),
                            modifier = Modifier
                                .requiredWidth(160.dp)
                                .rotate(-90f),
                        )
                    }
                    Text(
                        "${(confidence * 100).roundToInt()}%",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color.White,
                    )
                }
            }
        }
    }

/** FPS chip (spec §2.1). */
@Composable
private fun FpsChip(fps: Float) {
    val fpsColor = when {
        fps < 15f -> IosColors.Red
        fps < 25f -> IosColors.Orange
        fps < 30f -> IosColors.Yellow
        else -> IosColors.Green
    }
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(IosColors.Material.copy(alpha = 0.55f), RoundedCornerShape(12.dp))
            .border(1.25.dp, fpsColor, RoundedCornerShape(12.dp))
            .padding(vertical = 8.dp, horizontal = 10.dp),
    ) {
        Icon(Icons.Default.Speed, null, tint = fpsColor, modifier = Modifier.size(12.dp))
        Text("%.2f".format(fps), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Color.White)
        Text("FPS", fontSize = 11.sp, fontWeight = FontWeight.Medium, color = Color.White.copy(alpha = 0.8f))
    }
}

/** Object-count chip (spec §2.1). */
@Composable
private fun CountChip(count: Int) {
    val countColor = when {
        count == 0 -> IosColors.Gray
        count <= 3 -> IosColors.Blue
        count <= 6 -> IosColors.Orange
        count <= 10 -> IosColors.Red
        else -> IosColors.Purple
    }
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(IosColors.Material.copy(alpha = 0.85f), RoundedCornerShape(12.dp))
            .border(1.5.dp, countColor, RoundedCornerShape(12.dp))
            .padding(vertical = 8.dp, horizontal = 12.dp),
    ) {
        Icon(Icons.Default.Visibility, null, tint = countColor, modifier = Modifier.size(12.dp))
        Text("$count", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Color.White)
    }
}

/** 44dp glass circle button (spec §2.4). */
@Composable
fun CircleControlButton(
    ringColor: Color = Color.White.copy(alpha = 0.2f),
    ringWidth: Dp = 1.dp,
    fillColor: Color = Color.Black.copy(alpha = 0.32f),
    onClick: () -> Unit,
    content: @Composable () -> Unit,
) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(fillColor, CircleShape)
            .border(ringWidth, ringColor, CircleShape)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            ),
    ) { content() }
}

/** iOS-style dark segmented control (spec §2.4 item 1 — NOT Material3). */
@Composable
fun IosSegmentedControl(
    options: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    BoxWithConstraints(
        modifier = modifier
            .height(36.dp)
            .clip(RoundedCornerShape(9.dp))
            .background(Color(0xFF767680).copy(alpha = 0.24f), RoundedCornerShape(9.dp))
            .padding(2.dp)
    ) {
        val segWidth = maxWidth / options.size
        val thumbOffset by animateDpAsState(
            targetValue = segWidth * selectedIndex,
            animationSpec = tween(200),
            label = "segThumb",
        )
        // Sliding thumb
        Box(
            Modifier
                .offset(x = thumbOffset)
                .width(segWidth)
                .fillMaxSize()
                .clip(RoundedCornerShape(7.dp))
                .background(Color(0xFF636366), RoundedCornerShape(7.dp))
        )
        Row(Modifier.fillMaxSize()) {
            options.forEachIndexed { i, label ->
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .width(segWidth)
                        .fillMaxSize()
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                        ) { onSelect(i) },
                ) {
                    Text(label, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = Color.White)
                }
            }
        }
    }
}
