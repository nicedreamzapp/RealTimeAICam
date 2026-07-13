package com.mattmacosko.realtimeaicam.ui

import androidx.activity.compose.BackHandler
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBackIosNew
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.mattmacosko.realtimeaicam.camera.DetectionPipeline

/** iOS AppMode state machine (UI_SPEC §0): no tabs, no nav bar. */
enum class AppMode { Home, ObjectDetection, OcrEnglish, OcrSpanish }

/** Root router. Launch → Home always; camera modes ↔ Home only. */
@Composable
fun MainScreen(
    mode: AppMode,
    onModeChange: (AppMode) -> Unit,
    hasCameraPermission: Boolean,
    onRequestPermission: () -> Unit,
    pipeline: DetectionPipeline,
    versionLabel: String,
) {
    BackHandler(enabled = mode != AppMode.Home) { onModeChange(AppMode.Home) }

    val context = LocalContext.current

    // iOS parity: the iPhone interface is portrait-only (pbxproj
    // UISupportedInterfaceOrientations = Portrait) and LiveOCRView has no
    // orientation handling, so Home + both OCR screens lock portrait here.
    // Detection is the one screen that rearranges for sideways holding on
    // iOS, so it alone rotates freely.
    val activity = context as? android.app.Activity
    DisposableEffect(mode) {
        activity?.requestedOrientation =
            if (mode == AppMode.ObjectDetection) {
                android.content.pm.ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            } else {
                android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            }
        onDispose { }
    }

    var showInstructions by androidx.compose.runtime.saveable.rememberSaveable {
        androidx.compose.runtime.mutableStateOf(false)
    }
    // Auto-show on very first launch (iOS: hasShownInstructions)
    androidx.compose.runtime.LaunchedEffect(Unit) {
        val prefs = context.getSharedPreferences("rtaicam", android.content.Context.MODE_PRIVATE)
        if (!prefs.getBoolean("hasShownInstructions", false)) {
            prefs.edit().putBoolean("hasShownInstructions", true).apply()
            showInstructions = true
        }
    }

    var showVoiceGrid by remember { androidx.compose.runtime.mutableStateOf(false) }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        when (mode) {
            AppMode.Home -> {
                val voiceModel = rememberVoicePickerModel(context)
                HomeScreen(
                    versionLabel = versionLabel,
                    voiceLabel = voiceModel.selected?.display ?: "System Voice",
                    voiceEmoji = voiceModel.selected?.emoji ?: "🧑",
                    onEnglishOcr = { onModeChange(AppMode.OcrEnglish) },
                    onSpanishOcr = { onModeChange(AppMode.OcrSpanish) },
                    onObjectDetection = { onModeChange(AppMode.ObjectDetection) },
                    onInfo = { showInstructions = true },
                    onVoicePicker = { showVoiceGrid = true },
                )
                if (showVoiceGrid) {
                    VoiceGridPopup(voiceModel, onDismiss = { showVoiceGrid = false })
                }
            }

            AppMode.ObjectDetection -> CameraGate(hasCameraPermission, onRequestPermission) {
                DetectionScreen(pipeline, onBack = { onModeChange(AppMode.Home) })
            }

            AppMode.OcrEnglish -> CameraGate(hasCameraPermission, onRequestPermission) {
                OcrScreen(isSpanish = false, onBack = { onModeChange(AppMode.Home) })
            }

            AppMode.OcrSpanish -> CameraGate(hasCameraPermission, onRequestPermission) {
                OcrScreen(isSpanish = true, onBack = { onModeChange(AppMode.Home) })
            }
        }

        // Instructions sheet over Home (first launch + INFO button)
        InstructionsSheet(
            visible = showInstructions && mode == AppMode.Home,
            onDismiss = { showInstructions = false },
        )
    }
}

@Composable
private fun CameraGate(
    hasPermission: Boolean,
    onRequestPermission: () -> Unit,
    content: @Composable () -> Unit,
) {
    if (hasPermission) content() else PermissionRequest(onRequestPermission)
}

/** "‹ Back" glass pill (UI_SPEC §2.1). */
@Composable
fun BackPill(onBack: () -> Unit) {
    val debouncer = rememberDebouncer(1000)
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(IosColors.Material.copy(alpha = 0.72f), RoundedCornerShape(20.dp))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = { if (debouncer.tryFire()) onBack() },
            )
            .padding(vertical = 10.dp, horizontal = 16.dp),
    ) {
        Icon(
            Icons.Default.ArrowBackIosNew,
            contentDescription = "Back",
            tint = Color.White,
            modifier = Modifier.size(16.dp),
        )
        Text("Back", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Color.White)
    }
}

/** Temporary OCR screen shell until tiers 5-6 (Back + mode chip only). */
@Composable
private fun OcrPlaceholder(modeLabel: String, onBack: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 40.dp, start = 20.dp, end = 20.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.Top,
        ) {
            BackPill(onBack)
            Text(
                modeLabel,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = Color.White,
                modifier = Modifier
                    .clip(RoundedCornerShape(20.dp))
                    .background(IosColors.Material.copy(alpha = 0.85f), RoundedCornerShape(20.dp))
                    .padding(horizontal = 12.dp, vertical = 10.dp),
            )
        }
        Text(
            "Live OCR coming in the next build",
            color = Color.White.copy(alpha = 0.6f),
            fontSize = 14.sp,
            modifier = Modifier.align(Alignment.Center),
        )
    }
}

/** Object Detection screen — camera + overlay + iOS chrome (UI_SPEC §2). */
@Composable
fun DetectionScreen(pipeline: DetectionPipeline, onBack: () -> Unit) {
    val lifecycleOwner = LocalLifecycleOwner.current
    val context = LocalContext.current
    val state by pipeline.uiState.collectAsState()

    val previewView = remember {
        PreviewView(context).apply {
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
    }

    DisposableEffect(lifecycleOwner) {
        pipeline.start(lifecycleOwner, previewView)
        onDispose { pipeline.stop() }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())

        // Pinch-to-zoom layer (under the chrome, over the preview)
        Box(
            Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    detectTransformGestures { _, _, zoom, _ ->
                        if (zoom != 1f) pipeline.onPinch(zoom)
                    }
                }
        )

        DetectionOverlay(
            detections = state.detections,
            frameWidth = state.frameWidth,
            frameHeight = state.frameHeight,
            modifier = Modifier.fillMaxSize(),
        )

        DetectionChrome(state = state, pipeline = pipeline, onBack = onBack)

        // Graceful on-screen failure when the model asset is missing
        state.modelError?.let { error ->
            Box(
                modifier = Modifier
                    .align(Alignment.Center)
                    .padding(24.dp)
                    .background(Color(0xE6202020), RoundedCornerShape(16.dp))
                    .padding(20.dp)
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        text = "Model not loaded",
                        color = IosColors.Red,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        text = error,
                        color = Color.White.copy(alpha = 0.85f),
                        fontSize = 13.sp,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                }
            }
        }
    }
}

@Composable
fun PermissionRequest(onRequestPermission: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = "RealTime AI Cam needs the camera to detect objects.",
            color = Color.White,
            fontSize = 16.sp,
            textAlign = TextAlign.Center,
        )
        Button(
            onClick = onRequestPermission,
            modifier = Modifier.padding(top = 20.dp),
        ) {
            Text("Grant camera access")
        }
    }
}
