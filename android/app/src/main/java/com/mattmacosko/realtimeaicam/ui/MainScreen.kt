package com.mattmacosko.realtimeaicam.ui

import androidx.compose.ui.res.stringResource
import com.mattmacosko.realtimeaicam.R
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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.mattmacosko.realtimeaicam.camera.DetectionPipeline

/** iOS AppMode state machine (UI_SPEC §0): no tabs, no nav bar. */
enum class AppMode { Home, ObjectDetection, OcrEnglish, OcrSpanish, WhatsThis, HelpMeAim }

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

    // The rating card is asked for right after a result is read aloud (RatePrompt), not here.

    val context = LocalContext.current

    // Your language, said once on the first launch when the phone is in a language the app can
    // translate into (and not English). Nothing downloads; Settings has the download row.
    androidx.compose.runtime.LaunchedEffect(Unit) {
        val p = context.getSharedPreferences(com.mattmacosko.realtimeaicam.translation.YourLanguage.PREFS, android.content.Context.MODE_PRIVATE)
        val announced = p.getBoolean(com.mattmacosko.realtimeaicam.translation.YourLanguage.ANNOUNCED_KEY, false)
        val phone = com.mattmacosko.realtimeaicam.translation.YourLanguage.phoneLanguage()
        if (com.mattmacosko.realtimeaicam.translation.YourLanguageRules.shouldAnnounceFirstLaunch(phone, announced)) {
            p.edit().putBoolean(com.mattmacosko.realtimeaicam.translation.YourLanguage.ANNOUNCED_KEY, true).apply()
            val line = com.mattmacosko.realtimeaicam.translation.YourLanguageRules.firstLaunchLine(
                com.mattmacosko.realtimeaicam.translation.YourLanguage.code(context))
            android.util.Log.i("YourLanguage", "first launch: $line")
            AppVoice.get(context).speak(line)
        }
    }

    // iOS parity: the iPhone interface is portrait-only (pbxproj
    // UISupportedInterfaceOrientations = Portrait) and LiveOCRView has no
    // orientation handling, so Home + both OCR screens lock portrait here.
    // Detection is the one screen that rearranges for sideways holding on
    // iOS, so it alone rotates freely.
    // LocalContext may be AppLang's language wrapper around the activity: unwrap it.
    val activity = remember(context) {
        var c: android.content.Context? = context
        while (c is android.content.ContextWrapper && c !is android.app.Activity) c = c.baseContext
        c as? android.app.Activity
    }
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
    var showHomeSettings by remember { androidx.compose.runtime.mutableStateOf(false) }
    // A voice for the home screen's own lines (Live Cam coming soon, Home), made on first use.
    var homeVoice by remember { androidx.compose.runtime.mutableStateOf<com.mattmacosko.realtimeaicam.camera.SpeechAnnouncer?>(null) }
    DisposableEffect(Unit) { onDispose { homeVoice?.shutdown() } }
    fun homeCue(line: String, stillWanted: () -> Boolean = { true }) {
        val voice = homeVoice ?: com.mattmacosko.realtimeaicam.camera.SpeechAnnouncer(context)
            .also { homeVoice = it }
        voice.cue(line, stillWanted)
    }
    // Done on the guide (first-time-user test, 2026-11-04): home came back in silence with
    // TalkBack's focus on nothing. Now "Home" is said, then TalkBack lands on Settings.
    val view = androidx.compose.ui.platform.LocalView.current
    var guideClosed by remember { androidx.compose.runtime.mutableIntStateOf(0) }
    // The mode now, not when the guide closed: leaving home during the waits drops the cue.
    val currentMode by androidx.compose.runtime.rememberUpdatedState(mode)
    androidx.compose.runtime.LaunchedEffect(guideClosed) {
        if (guideClosed == 0 || currentMode != AppMode.Home) return@LaunchedEffect
        if (!A11yFocus.awaitWindowFocus(view) || currentMode != AppMode.Home) return@LaunchedEffect
        homeCue(com.mattmacosko.realtimeaicam.camera.UiCue.HOME) { currentMode == AppMode.Home }
        if (com.mattmacosko.realtimeaicam.camera.UiCue.screenReaderOn(context)) {
            kotlinx.coroutines.delay(com.mattmacosko.realtimeaicam.camera.UiCue.HOME_FOCUS_DELAY_MS)
            if (currentMode == AppMode.Home) A11yFocus.moveToSoon(view, HOME_FIRST_CONTROL_TAG)
        }
    }
    // Live Cam's "coming soon", also on screen: with the volume at 0 the spoken line alone
    // left the tap with no feedback at all (Cricket, 2026-11-04). Each tap restarts it.
    var liveCamTaps by remember { androidx.compose.runtime.mutableIntStateOf(0) }
    var liveCamNoteShown by remember { androidx.compose.runtime.mutableStateOf(false) }
    androidx.compose.runtime.LaunchedEffect(liveCamTaps) {
        if (liveCamTaps == 0) return@LaunchedEffect
        liveCamNoteShown = true
        kotlinx.coroutines.delay(LIVE_CAM_NOTE_MS)
        liveCamNoteShown = false
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        when (mode) {
            AppMode.Home -> {
                val voiceModel = rememberVoicePickerModel(context)
                HomeScreen(
                    versionLabel = versionLabel,
                    voiceLabel = voiceModel.selected?.display ?: stringResource(R.string.e_voice_system),
                    voiceEmoji = voiceModel.selected?.emoji ?: "🧑",
                    // Read + Translate are one button; it opens the way it was left.
                    onRead = {
                        onModeChange(
                            if (com.mattmacosko.realtimeaicam.translation.ReaderChoice.opensTranslating(context)) {
                                AppMode.OcrSpanish
                            } else {
                                AppMode.OcrEnglish
                            }
                        )
                    },
                    onObjectDetection = { onModeChange(AppMode.ObjectDetection) },
                    onWhatsThis = { onModeChange(AppMode.WhatsThis) },
                    onHelpMeAim = { onModeChange(AppMode.HelpMeAim) },
                    // Layout only for now: the button is there, Live Cam itself is not built yet.
                    onLiveCam = {
                        // Said once: by TalkBack when it is on, else by the app's voice (it was
                        // heard twice, 2026-11-04). Also shown on screen below.
                        homeCue(com.mattmacosko.realtimeaicam.camera.UiCue.LIVE_CAM_COMING_SOON)
                        liveCamTaps++
                    },
                    onSettings = { showHomeSettings = true },
                    onInfo = { showInstructions = true },
                    onVoicePicker = { showVoiceGrid = true },
                )
                androidx.compose.animation.AnimatedVisibility(
                    visible = liveCamNoteShown,
                    enter = androidx.compose.animation.fadeIn(),
                    exit = androidx.compose.animation.fadeOut(),
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        // The bars and cutout read live from the window, like the Volume-is-off
                        // banner: Compose kept portrait insets after a rotation, so in landscape
                        // the note could sit under a side nav bar (11/04 review).
                        .liveSafePadding(horizontal = true, bottom = true)
                        .padding(bottom = 96.dp, start = 24.dp, end = 24.dp),
                ) {
                    Text(
                        stringResource(R.string.e_cue_live_cam_soon),
                        color = Color.White,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.SemiBold,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .clip(RoundedCornerShape(16.dp))
                            .background(Color(0xF0202024), RoundedCornerShape(16.dp))
                            .padding(horizontal = 20.dp, vertical = 14.dp)
                            .testTag("liveCamComingSoon"),
                    )
                }
                if (showVoiceGrid) {
                    VoiceGridPopup(voiceModel, onDismiss = { showVoiceGrid = false })
                }
                if (showHomeSettings) {
                    BackHandler { showHomeSettings = false }
                    SettingsOverlay(zoom = 1f, onDismiss = { showHomeSettings = false }, fromHome = true)
                }
            }

            AppMode.ObjectDetection -> CameraGate(hasCameraPermission, onRequestPermission) {
                DetectionScreen(pipeline, onBack = { onModeChange(AppMode.Home) })
            }

            AppMode.OcrEnglish -> CameraGate(hasCameraPermission, onRequestPermission) {
                OcrScreen(
                    isSpanish = false,
                    onBack = { onModeChange(AppMode.Home) },
                    onSwitchReader = { onModeChange(if (it) AppMode.OcrSpanish else AppMode.OcrEnglish) },
                )
            }

            AppMode.OcrSpanish -> CameraGate(hasCameraPermission, onRequestPermission) {
                OcrScreen(
                    isSpanish = true,
                    onBack = { onModeChange(AppMode.Home) },
                    onSwitchReader = { onModeChange(if (it) AppMode.OcrSpanish else AppMode.OcrEnglish) },
                )
            }

            AppMode.WhatsThis -> CameraGate(hasCameraPermission, onRequestPermission) {
                WhatsThisScreen(detection = pipeline, onBack = { onModeChange(AppMode.Home) })
            }

            AppMode.HelpMeAim -> CameraGate(hasCameraPermission, onRequestPermission) {
                com.mattmacosko.realtimeaicam.aim.HelpMeAimScreen(
                    onBack = { onModeChange(AppMode.Home) },
                )
            }
        }

        // Instructions sheet over Home (first launch + INFO button)
        InstructionsSheet(
            visible = showInstructions && mode == AppMode.Home,
            onDismiss = {
                showInstructions = false
                guideClosed++
            },
        )
    }
}

/** The home screen's first control, where TalkBack lands after the guide closes. */
const val HOME_FIRST_CONTROL_TAG = "homeSettings"
private const val LIVE_CAM_NOTE_MS = 3_000L

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
            contentDescription = stringResource(R.string.e_back),
            tint = Color.White,
            modifier = Modifier.size(16.dp),
        )
        Text(stringResource(R.string.e_back), fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Color.White)
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
            stringResource(R.string.e_live_ocr_soon),
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
                        text = stringResource(R.string.e_model_not_loaded),
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
            text = stringResource(R.string.e_camera_needed),
            color = Color.White,
            fontSize = 16.sp,
            textAlign = TextAlign.Center,
        )
        Button(
            onClick = onRequestPermission,
            modifier = Modifier.padding(top = 20.dp),
        ) {
            Text(stringResource(R.string.e_grant_camera))
        }
    }
}
