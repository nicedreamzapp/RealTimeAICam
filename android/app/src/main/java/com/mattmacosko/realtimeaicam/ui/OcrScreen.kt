package com.mattmacosko.realtimeaicam.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.camera.view.PreviewView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.FlashlightOff
import androidx.compose.material.icons.filled.FlashlightOn
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Translate
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.mattmacosko.realtimeaicam.camera.OcrPipeline

/** Copy history: last 5 unique strings, newest first (SharedPreferences). */
object CopyHistory {
    private const val KEY = "copy_history_v1"
    private const val SEP = "\u0001"

    fun get(context: Context): List<String> =
        context.getSharedPreferences("rtaicam", Context.MODE_PRIVATE)
            .getString(KEY, "")!!.split(SEP).filter { it.isNotBlank() }

    fun add(context: Context, text: String) {
        val list = (listOf(text) + get(context).filter { it != text }).take(5)
        context.getSharedPreferences("rtaicam", Context.MODE_PRIVATE)
            .edit().putString(KEY, list.joinToString(SEP)).apply()
    }

    fun clear(context: Context) {
        context.getSharedPreferences("rtaicam", Context.MODE_PRIVATE)
            .edit().remove(KEY).apply()
    }
}

private fun copyToClipboard(context: Context, text: String) {
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    cm.setPrimaryClip(ClipData.newPlainText("RealTime AI Cam", text))
    CopyHistory.add(context, text)
}

/** Live OCR screen — English and Spanish→English modes (UI_SPEC §3). */
@Composable
fun OcrScreen(isSpanish: Boolean, onBack: () -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    val pipeline = remember { OcrPipeline(context, isSpanish) }
    val previewView = remember {
        PreviewView(context).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }
    }

    DisposableEffect(lifecycleOwner) {
        pipeline.start(lifecycleOwner, previewView)
        onDispose { pipeline.shutdown() }
    }

    val text by pipeline.recognizedText.collectAsState()
    val translated by pipeline.translatedText.collectAsState()
    val translating by pipeline.isTranslating.collectAsState()
    val showPopup by pipeline.showTranslationPopup.collectAsState()
    val torchOn by pipeline.torchOn.collectAsState()
    val zoom by pipeline.zoomRatio.collectAsState()
    val isSpeaking by pipeline.isSpeaking.collectAsState()

    var showSettings by remember { mutableStateOf(false) }
    var showTorchPopup by remember { mutableStateOf(false) }
    var torchPreset by remember { mutableStateOf(100) }
    val debouncer = rememberDebouncer(500)

    // Torch popup dismisses on rotation instead of floating mid-screen
    val orientation = LocalConfiguration.current.orientation
    LaunchedEffect(orientation) { showTorchPopup = false }

    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        val fullWidth = maxWidth
        AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())

        // Pinch-to-zoom
        Box(
            Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    detectTransformGestures { _, _, zoomChange, _ ->
                        if (zoomChange != 1f) pipeline.onPinch(zoomChange)
                    }
                }
        )

        // Scrims (spec §3.1)
        Box(
            Modifier
                .fillMaxWidth()
                .height(120.dp)
                .background(
                    Brush.verticalGradient(
                        listOf(Color.Black.copy(alpha = 0.6f), Color.Transparent)
                    )
                )
        )
        Box(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(250.dp)
                .background(
                    Brush.verticalGradient(
                        listOf(Color.Transparent, Color.Black.copy(alpha = 0.7f))
                    )
                )
        )

        // Top bar (spec §3.2) — inset from cutout + nav bar in landscape
        Row(
            Modifier
                .fillMaxWidth()
                .windowInsetsPadding(
                    WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)
                )
                .padding(top = 40.dp, start = 20.dp, end = 20.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.Top,
        ) {
            BackPill(onBack)
            Text(
                if (isSpanish) "Span → Eng" else "English",
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = Color.White,
                modifier = Modifier
                    .clip(RoundedCornerShape(20.dp))
                    .background(IosColors.Material.copy(alpha = 0.85f), RoundedCornerShape(20.dp))
                    .padding(horizontal = 12.dp, vertical = 10.dp),
            )
        }

        // Zoom pill
        AnimatedVisibility(
            visible = zoom < 0.95f || zoom > 1.05f,
            enter = fadeIn(tween(200)),
            exit = fadeOut(tween(200)),
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = 100.dp),
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

        // Recognized-text card (spec §3.3) — anchored above the FIXED button row
        AnimatedVisibility(
            visible = text.isNotEmpty(),
            enter = slideInVertically(tween(250)) { it / 2 } + fadeIn(tween(250)),
            exit = slideOutVertically(tween(200)) { it / 2 } + fadeOut(tween(200)),
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 122.dp, start = 20.dp, end = 20.dp),
        ) {
            val displayText = translated ?: text
            val isTranslationShown = translated != null
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(IosColors.Material.copy(alpha = 0.90f), RoundedCornerShape(16.dp))
                    .clickable(
                        enabled = isSpanish && isTranslationShown,
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                    ) { pipeline.showTranslationPopup.value = true }
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        Modifier
                            .size(8.dp)
                            .background(
                                if (isTranslationShown) IosColors.Green else IosColors.Blue,
                                CircleShape,
                            )
                    )
                    Text(
                        when {
                            !isSpanish -> "Detected"
                            isTranslationShown -> "Translation"
                            else -> "Spanish Text"
                        },
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                        color = Color.White.copy(alpha = 0.9f),
                    )
                    Spacer(Modifier.weight(1f))
                    if (translating) AnimatedLoader(22.dp)
                }
                Text(
                    displayText,
                    fontSize = 16.sp,
                    color = Color.White,
                    modifier = Modifier
                        .heightIn(max = 100.dp)
                        .verticalScroll(rememberScrollState()),
                )
            }
        }

        // Bottom button row (spec §3.4) — FIXED anchor, popups float separately
        Row(
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(bottom = 32.dp, start = 20.dp, end = 20.dp),
        ) {
            // 1. Settings
            CircleControlButton(onClick = { showSettings = true }) {
                Icon(Icons.Default.Settings, null, tint = Color.White, modifier = Modifier.size(22.dp))
            }
            // 2. Torch
            CircleControlButton(
                ringColor = if (torchOn) IosColors.Yellow.copy(alpha = 0.5f) else Color.White.copy(alpha = 0.2f),
                onClick = {
                    if (torchOn) pipeline.setTorch(false) else showTorchPopup = !showTorchPopup
                },
            ) {
                Icon(
                    if (torchOn) Icons.Default.FlashlightOn else Icons.Default.FlashlightOff,
                    null,
                    tint = if (torchOn) IosColors.Yellow else Color.White,
                    modifier = Modifier.size(20.dp),
                )
            }
            // 3. Translate (Spanish, pre-translation) or Copy
            if (isSpanish && translated == null) {
                CircleControlButton(onClick = {
                    if (debouncer.tryFire()) pipeline.translate()
                }) {
                    Icon(
                        Icons.Default.Translate,
                        null,
                        tint = Color.White.copy(alpha = if (translating) 0.6f else 1f),
                        modifier = Modifier.size(22.dp),
                    )
                }
            } else {
                CircleControlButton(onClick = {
                    val t = translated ?: text
                    if (t.isNotBlank()) copyToClipboard(context, t)
                }) {
                    Icon(Icons.Default.ContentCopy, null, tint = Color.White, modifier = Modifier.size(22.dp))
                }
            }
            // 4. Speak — green fill ONLY while TTS audio is actually playing
            // (iOS speakButton: Color.green.opacity(0.3) when isSpeaking)
            CircleControlButton(
                fillColor = if (isSpeaking) IosColors.Green.copy(alpha = 0.30f)
                else Color.Black.copy(alpha = 0.32f),
                onClick = {
                    if (debouncer.tryFire()) pipeline.speakCurrent()
                },
            ) {
                Icon(Icons.Default.RecordVoiceOver, null, tint = Color.White, modifier = Modifier.size(22.dp))
            }
            // 5. Reset
            CircleControlButton(onClick = { pipeline.reset() }) {
                Icon(Icons.Default.Refresh, null, tint = Color.White, modifier = Modifier.size(22.dp))
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

        // Torch preset popup — floating layer above the torch button (2 of 5),
        // anchored like the detection screen (spec §3.4)
        AnimatedVisibility(
            visible = showTorchPopup && !torchOn,
            enter = scaleIn(initialScale = 0.95f, animationSpec = tween(100)) + fadeIn(tween(100)),
            exit = scaleOut(targetScale = 0.95f, animationSpec = tween(100)) + fadeOut(tween(100)),
            modifier = Modifier
                .align(Alignment.BottomStart)
                .navigationBarsPadding()
                .padding(bottom = 122.dp)
                // torch-button center (SpaceEvenly, 5×44dp, 20dp side pad) − half popup width
                .offset(x = 52.dp + (fullWidth - 260.dp) / 3),
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

        // Translation Ready popup (spec §3.5)
        if (showPopup) {
            TranslationActionsPopup(
                onCopy = {
                    translated?.let { copyToClipboard(context, it) }
                    pipeline.showTranslationPopup.value = false
                },
                onContinue = { pipeline.showTranslationPopup.value = false },
                onNewScan = { pipeline.reset() },
            )
        }

        // Settings overlay (spec §3.7)
        if (showSettings) {
            SettingsOverlay(zoom = zoom, onDismiss = { showSettings = false })
        }
    }
}

/** Translation Ready popup (spec §3.5). */
@Composable
private fun TranslationActionsPopup(
    onCopy: () -> Unit,
    onContinue: () -> Unit,
    onNewScan: () -> Unit,
) {
    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.4f))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onContinue,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .widthIn(max = 320.dp)
                .clip(RoundedCornerShape(20.dp))
                .background(Color(0xF21E1E1E), RoundedCornerShape(20.dp))
                .border(1.dp, Color.White.copy(alpha = 0.2f), RoundedCornerShape(20.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) { /* consume */ }
                .padding(24.dp),
        ) {
            Text(
                "Translation Ready",
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color.White,
                modifier = Modifier.padding(bottom = 8.dp),
            )
            PopupActionButton("Copy Translation", Icons.Default.ContentCopy, IosColors.Blue, onCopy)
            PopupActionButton("Continue Reading", Icons.Default.Visibility, IosColors.Green, onContinue)
            PopupActionButton("New Scan", Icons.Default.Refresh, IosColors.Orange, onNewScan)
        }
    }
}

@Composable
private fun PopupActionButton(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    accent: Color,
    onClick: () -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(accent.copy(alpha = 0.30f), RoundedCornerShape(14.dp))
            .border(1.dp, accent.copy(alpha = 0.50f), RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 14.dp),
    ) {
        Spacer(Modifier.weight(1f))
        Icon(icon, null, tint = Color.White, modifier = Modifier.size(18.dp))
        Text(label, fontSize = 17.sp, fontWeight = FontWeight.Medium, color = Color.White)
        Spacer(Modifier.weight(1f))
    }
}

/** iOS AnimatedLoader (spec §3.6): sweep-gradient arc, rotating. */
@Composable
fun AnimatedLoader(size: androidx.compose.ui.unit.Dp) {
    val transition = rememberInfiniteTransition(label = "loader")
    val rotation by transition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(1100, easing = LinearEasing)),
        label = "rot",
    )
    val sweep by transition.animateFloat(
        initialValue = 0.08f,
        targetValue = 0.96f,
        animationSpec = infiniteRepeatable(tween(950), RepeatMode.Reverse),
        label = "sweep",
    )
    Canvas(Modifier.size(size)) {
        val stroke = Stroke(width = this.size.minDimension / 6f, cap = StrokeCap.Round)
        drawCircle(
            color = Color.White.copy(alpha = 0.18f),
            style = stroke,
            radius = (this.size.minDimension - stroke.width) / 2f,
        )
        rotate(rotation) {
            drawArc(
                brush = Brush.sweepGradient(
                    listOf(IosColors.Purple, IosColors.Blue, IosColors.Cyan, IosColors.Purple)
                ),
                startAngle = 0f,
                sweepAngle = 360f * sweep,
                useCenter = false,
                style = stroke,
                topLeft = Offset(stroke.width / 2f, stroke.width / 2f),
                size = androidx.compose.ui.geometry.Size(
                    this.size.width - stroke.width,
                    this.size.height - stroke.width,
                ),
            )
        }
    }
}

/** Settings overlay (spec §3.7): history, zoom, tips, privacy. */
@Composable
fun SettingsOverlay(zoom: Float, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var history by remember { mutableStateOf(CopyHistory.get(context)) }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.4f))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onDismiss,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .widthIn(max = 380.dp)
                .fillMaxWidth(0.92f)
                .heightIn(max = 600.dp)
                .clip(RoundedCornerShape(20.dp))
                .background(Color(0xE61E1E1E), RoundedCornerShape(20.dp))
                .border(1.dp, Color.White.copy(alpha = 0.2f), RoundedCornerShape(20.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) { /* consume */ },
        ) {
            // Header
            Row(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Settings", fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                Spacer(Modifier.weight(1f))
                Text(
                    "✕",
                    fontSize = 20.sp,
                    color = IosColors.Gray,
                    modifier = Modifier
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClick = onDismiss,
                        )
                        .padding(4.dp),
                )
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.15f)))

            Column(
                Modifier
                    .verticalScroll(rememberScrollState())
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                // Copy History
                SettingsCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Default.ContentCopy, null,
                            tint = IosColors.Orange, modifier = Modifier.size(20.dp),
                        )
                        Text(
                            "  Copy History", fontSize = 17.sp,
                            fontWeight = FontWeight.SemiBold, color = Color.White,
                        )
                        Spacer(Modifier.weight(1f))
                        if (history.isNotEmpty()) {
                            Text(
                                "Clear", fontSize = 12.sp, color = IosColors.Red,
                                modifier = Modifier.clickable {
                                    CopyHistory.clear(context)
                                    history = emptyList()
                                },
                            )
                        }
                    }
                    if (history.isEmpty()) {
                        Text(
                            "No copied text yet",
                            fontSize = 17.sp,
                            color = IosColors.Secondary,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 20.dp),
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        )
                    } else {
                        history.forEach { item ->
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(Color.White.copy(alpha = 0.08f), RoundedCornerShape(8.dp))
                                    .padding(12.dp),
                            ) {
                                Text(
                                    item,
                                    fontSize = 15.sp,
                                    fontFamily = FontFamily.Monospace,
                                    color = Color.White,
                                    maxLines = 2,
                                    modifier = Modifier.weight(1f),
                                )
                                Icon(
                                    Icons.Default.ContentCopy, null,
                                    tint = IosColors.Blue,
                                    modifier = Modifier
                                        .size(18.dp)
                                        .clickable { copyToClipboard(context, item) },
                                )
                            }
                        }
                    }
                }

                // Camera Zoom (only when zoomed)
                if (zoom < 0.95f || zoom > 1.05f) {
                    SettingsCard {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("🔍", fontSize = 18.sp)
                            Text(
                                "  Camera Zoom", fontSize = 17.sp,
                                fontWeight = FontWeight.SemiBold, color = Color.White,
                            )
                            Spacer(Modifier.weight(1f))
                            Text(
                                "%.1fx".format(zoom), fontSize = 20.sp,
                                fontWeight = FontWeight.Medium, color = IosColors.Purple,
                            )
                        }
                    }
                }

                // Tips
                SettingsCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("ℹ️", fontSize = 18.sp)
                        Text(
                            "  Tips", fontSize = 17.sp,
                            fontWeight = FontWeight.SemiBold, color = Color.White,
                        )
                    }
                    TipLine("• 🤏 Pinch to zoom the camera")
                    TipLine("• 📋 Copy detected/translated text")
                    TipLine("• 🔁 Reset/Stop — clears text, translation, and stops speaking")
                    TipLine("• 🗣️ Speak detected/translated text")
                    TipLine("• 🔦 Adjust flashlight")
                    TipLine("• ⚙️ Open settings/history")
                }

                // Private by Design
                SettingsCard(extraStroke = true) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("🔒", fontSize = 18.sp)
                        Text(
                            "  Private by Design", fontSize = 17.sp,
                            fontWeight = FontWeight.SemiBold, color = IosColors.Green,
                        )
                    }
                    TipLine("✈️ Works 100% offline — even in Airplane Mode")
                    TipLine("🙈 No tracking, no analytics, no accounts")
                    TipLine("📷 Camera frames are processed on-device only")
                    TipLine("📋 Copy history stays on this device")
                }
            }
        }
    }
}

@Composable
private fun SettingsCard(extraStroke: Boolean = false, content: @Composable () -> Unit) {
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(IosColors.MaterialLight.copy(alpha = 0.35f), RoundedCornerShape(12.dp))
            .then(
                if (extraStroke) Modifier.border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(12.dp))
                else Modifier
            )
            .padding(16.dp),
    ) { content() }
}

@Composable
private fun TipLine(text: String) {
    Text(text, fontSize = 13.sp, color = IosColors.Secondary, lineHeight = 19.sp)
}
