package com.mattmacosko.realtimeaicam.ui

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import android.view.Surface
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.CenterFocusWeak
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.FlashlightOff
import androidx.compose.material.icons.filled.FlashlightOn
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.mattmacosko.realtimeaicam.camera.SpeechAnnouncer
import com.mattmacosko.realtimeaicam.narrator.NarratorEngine
import com.mattmacosko.realtimeaicam.narrator.NarratorPrompt
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import kotlin.coroutines.resume
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * The iPhone's "What's this?" screen, laid out the way it is over there: the
 * live-OCR camera chrome (Back, the mode chip, the scrims, the six-button row
 * with flashlight, wide angle, copy, speak and reset), one purple button that
 * snaps the picture the instant it is pressed and holds that exact frame on
 * screen while the on-device model looks at it, then "Hold to ask about this"
 * and "Next shot". Everything runs on the phone — nothing here touches the
 * network.
 */
@Composable
fun WhatsThisScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()

    val speaker = remember { SpeechAnnouncer(context) }
    val engine = remember { NarratorEngine.get(context) }
    val camera = remember { WhatsThisCamera(context) }
    val listener = remember { AskListener(context) }
    val previewView = remember {
        PreviewView(context).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }
    }
    val debouncer = rememberDebouncer(500)

    val torchOn by camera.torchOn.collectAsState()
    val zoom by camera.zoomRatio.collectAsState()
    val hasUltraWide by camera.hasUltraWide.collectAsState()
    val isUltraWide by camera.isUltraWide.collectAsState()
    val isSpeaking by speaker.speakingNow.collectAsState()

    var ready by remember { mutableStateOf(false) }
    var modelMissing by remember { mutableStateOf(false) }
    var summary by remember { mutableStateOf("") }
    var isScanning by remember { mutableStateOf(false) }
    var frozenPhoto by remember { mutableStateOf<Bitmap?>(null) }
    var isListening by remember { mutableStateOf(false) }
    var isAsking by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    // Spoken countdown before the shutter, on by default. Asked for on AppleVis
    // (2026-09-12): pressing the button is itself what nudges the phone and blurs
    // the shot, and it is the only way to take a selfie you can't see to frame.
    val prefs = remember { context.getSharedPreferences("rtcam", Context.MODE_PRIVATE) }
    var countdownEnabled by remember {
        mutableStateOf(prefs.getBoolean("countdownBeforeCapture", true))
    }
    var countdownRemaining by remember { mutableStateOf<Int?>(null) }
    var countdownJob by remember { mutableStateOf<Job?>(null) }
    val haptics = LocalHapticFeedback.current

    val micPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (!granted) summary = "Microphone access is needed to ask a question. Allow it in Settings."
    }

    DisposableEffect(lifecycleOwner) {
        camera.start(lifecycleOwner, previewView)
        onDispose {
            camera.stop()
            listener.destroy()
            speaker.stop()
            speaker.shutdown()
        }
    }

    // Loading 736 MB takes a moment; do it while the user is still aiming.
    LaunchedEffect(Unit) {
        val ok = withContext(Dispatchers.IO) { engine.ensureLoaded() }
        ready = ok
        modelMissing = !ok
        if (!ok) summary = MODEL_MISSING
    }

    /** One place where a sentence becomes speech, so no path can drift. */
    fun say(sentence: String) {
        isScanning = false
        summary = sentence
        speaker.speak(sentence)
    }

    /** The primary action: snap now, freeze the frame, let the model look. */
    fun scanPage() {
        if (isScanning || !ready) return
        isScanning = true
        speaker.stop()
        summary = "Working it out…"
        scope.launch {
            val raw = File(context.cacheDir, "whats-this-raw.jpg")
            val shot = File(context.cacheDir, "whats-this.jpg")
            if (!camera.capture(raw)) {
                isScanning = false
                summary = "The camera couldn't take the picture. Try again."
                return@launch
            }
            // Hold this exact frame on screen — it's what the model is looking
            // at. Upright and no longer than 1024 px, exactly like the iPhone.
            val bitmap = withContext(Dispatchers.IO) { prepareShot(raw, shot) }
            if (bitmap == null) {
                isScanning = false
                summary = "The camera couldn't take the picture. Try again."
                return@launch
            }
            frozenPhoto = bitmap
            // Free the camera while the model thinks; it comes back the moment
            // the answer is spoken.
            camera.pause()
            try {
                // Paper gets the strict mail reader; anything else — a room, a
                // dog, a street — gets the scene describer.
                val question = if (looksLikeAPage(context, shot)) {
                    NarratorPrompt.PAGE_QUESTION
                } else {
                    NarratorPrompt.SCENE_QUESTION
                }
                val started = System.currentTimeMillis()
                val isPage = question == NarratorPrompt.PAGE_QUESTION
                val said = withContext(Dispatchers.IO) {
                    describeNeverRefusing(context, shot, question, isPage, engine)
                }
                Log.i(TAG, "answer in ${System.currentTimeMillis() - started} ms: $said")
                // No "get closer or add light" fallback: the person holding the
                // camera cannot see where it is pointing, so that is not advice
                // they can act on.
                say(said.ifBlank { "It's hard to see clearly, and I couldn't make out enough to say." })
            } finally {
                camera.resume(lifecycleOwner, previewView)
            }
        }
    }

    fun cancelCountdown() {
        countdownJob?.cancel()
        countdownJob = null
        countdownRemaining = null
        speaker.stop()
    }

    /**
     * The shutter as the button sees it: count out loud first, then take the
     * picture, so the hand is off the phone when it fires. With the countdown
     * switched off this is just the old one-tap capture.
     */
    fun startCapture() {
        if (isScanning || countdownRemaining != null) return
        if (!countdownEnabled) { scanPage(); return }
        speaker.stop()
        summary = ""
        countdownRemaining = 3
        countdownJob = scope.launch {
            for ((number, word) in listOf(3 to "three", 2 to "two", 1 to "one")) {
                countdownRemaining = number
                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                // The app says the count in its own voice rather than leaving it
                // to TalkBack, so it is heard the same way with TalkBack off.
                speaker.speak(word)
                delay(1000)
            }
            countdownRemaining = null
            countdownJob = null
            scanPage()
        }
    }

    /** Let go of the frozen shot and return to the live camera for a new one. */
    fun nextShot() {
        speaker.stop()
        summary = ""
        frozenPhoto = null
    }

    /** Hold-to-ask: begins listening while the button is held. */
    fun startAsk() {
        if (frozenPhoto == null || isListening || isAsking) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            micPermission.launch(Manifest.permission.RECORD_AUDIO)
            return
        }
        if (!listener.available) {
            summary = "Voice questions aren't available on this phone."
            return
        }
        speaker.stop()
        isListening = true
        listener.start()
    }

    /** Let go: transcribe the question on-device, answer it about the frozen photo. */
    fun finishAsk() {
        if (!isListening) return
        isListening = false
        scope.launch {
            val heard = listener.stopAndTranscribe().trim()
            val photo = File(context.cacheDir, "whats-this.jpg")
            if (heard.isEmpty() || frozenPhoto == null || !photo.isFile) {
                summary = "I didn't catch that. Hold the button and ask again."
                return@launch
            }
            isAsking = true
            summary = "Thinking…"
            val answer = withContext(Dispatchers.IO) {
                var said = engine.describe(photo, heard)
                if (looksLikeRefusal(said)) {
                    said = engine.describe(
                        photo,
                        "Answer this question as best you can from the photo, even if it is unclear. " +
                            "Do not refuse. Question: $heard",
                    )
                }
                said
            }
            isAsking = false
            say(answer.ifBlank { "Sorry, I couldn't work that out. Try asking again." })
        }
    }

    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        val fullWidth = maxWidth
        AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())

        // Pinch-to-zoom (live camera only)
        if (frozenPhoto == null) {
            Box(
                Modifier
                    .fillMaxSize()
                    .pointerInput(Unit) {
                        detectTransformGestures { _, _, zoomChange, _ ->
                            if (zoomChange != 1f) camera.onPinch(zoomChange)
                        }
                    }
            )
        }

        // The shot you just took, held on screen over the live preview until
        // you choose Next shot. Fit (on black) shows the WHOLE frame the model
        // actually looked at, not a cropped fill.
        frozenPhoto?.let { photo ->
            Image(
                bitmap = photo.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize().background(Color.Black),
            )
        }

        // Scrims
        Box(
            Modifier
                .fillMaxWidth()
                .height(120.dp)
                .background(
                    Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.6f), Color.Transparent))
                )
        )
        Box(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(250.dp)
                .background(
                    Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.7f)))
                )
        )

        // Top bar: Back + mode chip
        Row(
            Modifier
                .fillMaxWidth()
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal))
                .padding(top = 40.dp, start = 20.dp, end = 20.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.Top,
        ) {
            BackPill(onBack)
            Text(
                "What's this?",
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = Color.White,
                modifier = Modifier
                    .clip(RoundedCornerShape(20.dp))
                    .background(IosColors.Material.copy(alpha = 0.85f), RoundedCornerShape(20.dp))
                    .padding(horizontal = 12.dp, vertical = 10.dp)
                    .semantics { contentDescription = "Mode, summarizing what you point at" },
            )
        }

        // Zoom pill
        AnimatedVisibility(
            visible = frozenPhoto == null && (zoom < 0.95f || zoom > 1.05f),
            enter = fadeIn(tween(200)),
            exit = fadeOut(tween(200)),
            modifier = Modifier.align(Alignment.TopCenter).padding(top = 100.dp),
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

        // Summary card + primary action, stacked above the FIXED button row
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(bottom = 108.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            AnimatedVisibility(
                visible = summary.isNotEmpty(),
                enter = slideInVertically(tween(250)) { it / 2 } + fadeIn(tween(250)),
                exit = slideOutVertically(tween(200)) { it / 2 } + fadeOut(tween(200)),
                modifier = Modifier.padding(horizontal = 20.dp),
            ) {
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(IosColors.Material.copy(alpha = 0.90f), RoundedCornerShape(16.dp))
                        .clickable(
                            enabled = !isScanning && !isAsking && summary.isNotEmpty(),
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClickLabel = "Hear it again",
                        ) {
                            speaker.stop()
                            speaker.speak(summary)
                        }
                        .padding(16.dp)
                        .semantics(mergeDescendants = true) {
                            contentDescription = "Summary. $summary"
                        },
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(Modifier.size(8.dp).background(IosColors.Blue, CircleShape))
                        Text(
                            "Summary",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                            color = Color.White.copy(alpha = 0.9f),
                        )
                        Spacer(Modifier.weight(1f))
                        if (isScanning || isAsking) AnimatedLoader(22.dp)
                    }
                    Text(
                        summary,
                        fontSize = 16.sp,
                        color = Color.White,
                        modifier = Modifier
                            .heightIn(max = 100.dp)
                            .verticalScroll(rememberScrollState()),
                    )
                }
            }
            Spacer(Modifier.height(10.dp))

            // The primary action. Big, centred, the only thing you have to find:
            // aim and press. Once a shot is frozen it becomes Hold to ask +
            // Next shot, to let go and aim again.
            if (frozenPhoto != null && !isScanning) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 0.dp).padding(bottom = 14.dp),
                ) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(CapsuleShape)
                            .background(
                                (if (isListening) Color.Red else IosColors.Blue).copy(alpha = 0.8f),
                                CapsuleShape,
                            )
                            .border(1.5.dp, Color.White.copy(alpha = 0.5f), CapsuleShape)
                            .pointerInput(Unit) {
                                detectTapGestures(
                                    onPress = {
                                        startAsk()
                                        tryAwaitRelease()
                                        finishAsk()
                                    }
                                )
                            }
                            .padding(vertical = 16.dp)
                            .semantics(mergeDescendants = true) {
                                contentDescription = "Ask about this photo"
                                stateDescription = when {
                                    isListening -> "Listening"
                                    isAsking -> "Thinking"
                                    else -> "Hold, speak your question, then let go to hear the answer"
                                }
                            },
                    ) {
                        Icon(
                            when {
                                isListening -> Icons.Default.GraphicEq
                                isAsking -> Icons.Default.HourglassEmpty
                                else -> Icons.Default.Mic
                            },
                            null, tint = Color.White, modifier = Modifier.size(22.dp),
                        )
                        Text(
                            when {
                                isListening -> "Listening… let go to ask"
                                isAsking -> "Thinking…"
                                else -> "Hold to ask about this"
                            },
                            color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold,
                        )
                    }
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(CapsuleShape)
                            .background(IosColors.Purple.copy(alpha = 0.75f), CapsuleShape)
                            .border(1.5.dp, Color.White.copy(alpha = 0.5f), CapsuleShape)
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                                role = Role.Button,
                                onClickLabel = "Clear this photo and return to the camera for a new picture",
                            ) { if (debouncer.tryFire()) nextShot() }
                            .padding(vertical = 16.dp)
                            .semantics(mergeDescendants = true) { contentDescription = "Next shot" },
                    ) {
                        Icon(Icons.Default.CameraAlt, null, tint = Color.White, modifier = Modifier.size(22.dp))
                        Text("Next shot", color = Color.White, fontSize = 19.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            } else {
                val enabled = ready && !isScanning
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .padding(horizontal = 20.dp)
                        .padding(bottom = 14.dp)
                        .fillMaxWidth()
                        .clip(CapsuleShape)
                        .background(IosColors.Purple.copy(alpha = if (enabled) 0.75f else 0.35f), CapsuleShape)
                        .border(1.5.dp, Color.White.copy(alpha = 0.5f), CapsuleShape)
                        .clickable(
                            enabled = enabled,
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            role = Role.Button,
                            onClickLabel = if (countdownRemaining != null) {
                                "Stop the countdown without taking the picture"
                            } else {
                                "Take a picture and say what it is: a letter, a bill, a label, or whatever is in front of you"
                            },
                        ) { if (countdownRemaining == null) startCapture() else cancelCountdown() }
                        .padding(vertical = 16.dp)
                        .semantics(mergeDescendants = true) {
                            contentDescription = when {
                                isScanning -> "Looking"
                                countdownRemaining != null -> "Cancel countdown"
                                !ready && !modelMissing -> "Getting ready"
                                else -> "What's this?"
                            }
                        },
                ) {
                    Icon(
                        if (isScanning) Icons.Default.HourglassEmpty else Icons.Default.CenterFocusWeak,
                        null, tint = Color.White, modifier = Modifier.size(22.dp),
                    )
                    Text(
                        when {
                            isScanning -> "Looking…"
                            countdownRemaining != null -> "${countdownRemaining}…"
                            !ready && !modelMissing -> "Getting ready…"
                            else -> "What's this?"
                        },
                        color = Color.White, fontSize = 19.sp, fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }

        // Bottom button row — FIXED anchor, popups float separately
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
            CircleControlButton(
                label = "Settings",
                clickLabel = "Open settings, copy history and tips",
                onClick = { showSettings = true },
            ) {
                Icon(Icons.Default.Settings, null, tint = Color.White, modifier = Modifier.size(22.dp))
            }
            // 2. Torch — one tap on at full brightness, one tap off. No brightness
            // menu: AppleVis feedback (2026-09-12) was that picking a percentage
            // before any light appears costs several screen-reader flicks at the
            // exact moment you cannot see, and nobody wants a dim flashlight.
            CircleControlButton(
                ringColor = if (torchOn) IosColors.Yellow.copy(alpha = 0.5f) else Color.White.copy(alpha = 0.2f),
                label = "Flashlight",
                stateLabel = if (torchOn) "On" else "Off",
                clickLabel = if (torchOn) "Turn the flashlight off" else "Turn the flashlight on",
                onClick = { camera.setTorch(!torchOn) },
            ) {
                Icon(
                    if (torchOn) Icons.Default.FlashlightOn else Icons.Default.FlashlightOff,
                    null,
                    tint = if (torchOn) IosColors.Yellow else Color.White,
                    modifier = Modifier.size(20.dp),
                )
            }
            // 3. Wide angle (hidden on phones whose camera can't go below 1x, like iOS)
            if (hasUltraWide) {
                CircleControlButton(
                    label = if (isUltraWide) "Switch to normal camera" else "Switch to wide angle camera",
                    clickLabel = "Change how much the camera can see at once",
                    onClick = { if (debouncer.tryFire()) camera.toggleUltraWide() },
                ) {
                    Icon(
                        Icons.Default.GridView, null,
                        tint = if (isUltraWide) IosColors.Cyan else Color.White,
                        modifier = Modifier.size(22.dp),
                    )
                }
            }
            // 4. Copy the summary
            CircleControlButton(
                label = "Copy summary",
                clickLabel = "Copy the summary to the clipboard",
                onClick = { if (summary.isNotBlank() && !isScanning) copySummary(context, summary) },
            ) {
                Icon(Icons.Default.ContentCopy, null, tint = Color.White, modifier = Modifier.size(22.dp))
            }
            // 5. Speak — green ONLY while audio is actually playing
            CircleControlButton(
                fillColor = if (isSpeaking) IosColors.Green.copy(alpha = 0.30f) else Color.Black.copy(alpha = 0.32f),
                label = if (isSpeaking) "Stop reading" else "Say the summary again",
                stateLabel = if (isSpeaking) "Speaking" else "Not speaking",
                clickLabel = if (isSpeaking) "Stop speaking" else "Repeat the summary out loud",
                onClick = {
                    if (!debouncer.tryFire()) return@CircleControlButton
                    if (isSpeaking) speaker.stop()
                    else if (summary.isNotBlank() && !isScanning && !isAsking) speaker.speak(summary)
                },
            ) {
                Icon(Icons.Default.RecordVoiceOver, null, tint = Color.White, modifier = Modifier.size(22.dp))
            }
            // 6. Reset
            CircleControlButton(
                label = "Clear and stop",
                clickLabel = "Clear the summary and stop speaking",
                onClick = {
                    speaker.stop()
                    if (!isScanning && !isAsking) summary = ""
                },
            ) {
                Icon(Icons.Default.Refresh, null, tint = Color.White, modifier = Modifier.size(22.dp))
            }
        }


        if (showSettings) {
            SettingsOverlay(zoom = zoom, onDismiss = { showSettings = false })
        }
    }
}

private const val TAG = "WhatsThis"
private const val MODEL_LONG_SIDE = 512
private const val MODEL_MISSING = "The vision model is not installed on this phone yet."

private fun copySummary(context: Context, text: String) {
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    cm.setPrimaryClip(ClipData.newPlainText("RealTime AI Cam", text))
    CopyHistory.add(context, text)
}

/**
 * Ask, and keep asking until there is a description. Same four-step chain as the
 * iPhone: the plain question, a forced best-guess, a describe-only pass with the
 * page rules dropped, and finally a bare list of nouns. Each retry gets a
 * BRIGHTER copy of the photo — when the model says it is too dark, a brighter
 * picture is the useful answer, not a sterner question.
 */
private fun describeNeverRefusing(
    context: Context,
    shot: File,
    question: String,
    isPage: Boolean,
    engine: NarratorEngine,
): String {
    var said = engine.describe(shot, question)
    if (!looksLikeRefusal(said)) return said

    val brighter = brightenedCopy(context, shot, "whats-this-bright.jpg", 1.8f) ?: shot
    said = engine.describe(brighter, NarratorPrompt.forcedDescribe(isPage))
    if (!looksLikeRefusal(said)) return said

    val brightest = brightenedCopy(context, shot, "whats-this-brightest.jpg", 2.4f) ?: brighter
    said = engine.describe(brightest, NarratorPrompt.PLAIN_DESCRIBE, NarratorPrompt.DESCRIBE_ONLY)
    if (!looksLikeRefusal(said)) return said

    val listed = engine.describe(brightest, NarratorPrompt.LIST_THINGS, NarratorPrompt.DESCRIBE_ONLY)
    thingsOnly(listed)?.let {
        // Matt's words for how this should sound: "I'm having a hard time seeing
        // it, but this is what I think it is."
        return "It's hard to see clearly, but I think I can make out $it."
    }
    return strippingExcuses(said) ?: ""
}

/**
 * A brighter copy of the shot for the retry passes. A normal photo never goes
 * through this — only one the model already balked at.
 */
private fun brightenedCopy(context: Context, src: File, name: String, factor: Float): File? = try {
    val bitmap = BitmapFactory.decodeFile(src.path)
    if (bitmap == null) null else {
        val out = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
        val paint = Paint().apply {
            colorFilter = ColorMatrixColorFilter(
                ColorMatrix(
                    floatArrayOf(
                        factor, 0f, 0f, 0f, 0f,
                        0f, factor, 0f, 0f, 0f,
                        0f, 0f, factor, 0f, 0f,
                        0f, 0f, 0f, 1f, 0f,
                    )
                )
            )
        }
        Canvas(out).drawBitmap(bitmap, 0f, 0f, paint)
        val file = File(context.cacheDir, name)
        file.outputStream().use { out.compress(Bitmap.CompressFormat.JPEG, 90, it) }
        file
    }
} catch (t: Throwable) {
    Log.e(TAG, "could not brighten the shot", t)
    null
}

/**
 * Keep the comma-separated things and throw away any apology wrapped around
 * them. An instruction is not a thing: "hold the camera steady" came back from
 * the listing pass once and was read out as something visible in the room.
 */
private fun thingsOnly(raw: String): String? {
    var text = raw.trim().trim('"', '\'')
    if (text.isEmpty()) return null
    for (opener in listOf(
        "in this picture, i can see", "in this photo, i can see",
        "i can see", "i see", "the things i can see are",
        "here is a list", "here are the things",
    )) {
        if (text.lowercase().startsWith(opener)) {
            text = text.substring(opener.length)
            break
        }
    }
    val things = text.split(',', '\n', ';')
        .map { it.trim().trim('.', ':', '-', '*') }
        .filter { it.isNotEmpty() && it.length <= 40 && !looksLikeRefusal(it) && !isInstruction(it) }
    if (things.isEmpty()) return null
    val kept = things.take(4)
    return if (kept.size == 1) kept[0]
    else kept.dropLast(1).joinToString(", ") + " and " + kept.last()
}

private fun isInstruction(fragment: String): Boolean {
    val verbs = listOf(
        "hold", "move", "turn", "take", "try", "use", "ensure", "make sure",
        "point", "adjust", "increase", "retry", "please", "consider",
        "bring", "step", "add", "switch", "clean", "wipe", "check",
    )
    val f = fragment.lowercase().trim()
    return verbs.any { f.startsWith("$it ") || f == it }
}

/** Cut the excuse sentences out and speak whatever description is left. */
private fun strippingExcuses(sentence: String?): String? {
    if (sentence.isNullOrBlank()) return null
    val parts = sentence.split('.', '!', '?', ';')
        .map { it.trim() }
        .filter { it.isNotEmpty() }
    val described = parts.filter { !looksLikeRefusal(it) }
    if (described.isNotEmpty()) {
        val rebuilt = described.joinToString(". ") + "."
        if (rebuilt.length >= 12) return rebuilt
    }
    return "It's hard to see clearly, and I couldn't make out enough to say."
}

/** Same markers as the iPhone: an answer that only says to retake is a refusal. */
private fun looksLikeRefusal(s: String?): Boolean {
    val t = s?.lowercase() ?: return true
    // These must be REFUSAL phrases, not description words. "make out" on its own
    // flagged "I can make out a cat on a bed" as a refusal — and the forced retry
    // asks for exactly that wording, so every good answer was thrown away and the
    // chain fell through to the floor line. Match the whole phrase.
    val markers = listOf(
        "can't make out", "cannot make out", "can not make out",
        "couldn't make out", "could not make out",
        "can't see", "cannot see", "can't read", "cannot read",
        "can't tell", "cannot tell", "can't determine", "cannot determine",
        "unable to", "too dark to", "too blurry to", "too dark and blurry",
        "retake", "hold the camera still", "hold the phone still",
        "turn on a light", "turn on the flash", "add some light",
        "move closer", "take the picture again", "take it again",
        "try again", "not clear enough", "no details are visible",
    )
    return markers.any { t.contains(it) }
}

/**
 * Decode the capture upright (EXIF applied), cap the long side at 1024 px like
 * the iPhone, write that as the file the model reads, and hand back the bitmap
 * for the frozen frame. llama.cpp's image loader ignores EXIF, so the model
 * MUST be given rotated pixels or a portrait bill arrives sideways.
 */
private fun prepareShot(raw: File, out: File): Bitmap? = try {
    val decoded: Bitmap? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(raw)) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.isMutableRequired = false
            val long = max(info.size.width, info.size.height)
            decoder.setTargetSampleSize(max(1, long / 1024))
        }
    } else {
        BitmapFactory.decodeFile(raw.path, BitmapFactory.Options().apply { inSampleSize = 2 })
    }
    decoded?.let { bmp ->
        val long = max(bmp.width, bmp.height)
        val scaled = if (long > 1024) {
            val s = 1024f / long
            Bitmap.createScaledBitmap(bmp, (bmp.width * s).roundToInt(), (bmp.height * s).roundToInt(), true)
        } else bmp
        // The model gets a smaller copy than the screen does: the vision
        // encoder's work grows with the pixel count, and on a phone-class CPU
        // that encoder is most of the wait (1024 px = 5 min on a Helio P35).
        val modelLong = max(scaled.width, scaled.height)
        val forModel = if (modelLong > MODEL_LONG_SIDE) {
            val s = MODEL_LONG_SIDE.toFloat() / modelLong
            Bitmap.createScaledBitmap(scaled, (scaled.width * s).roundToInt(), (scaled.height * s).roundToInt(), true)
        } else scaled
        out.outputStream().use { forModel.compress(Bitmap.CompressFormat.JPEG, 90, it) }
        scaled
    }
} catch (t: Throwable) {
    Log.e(TAG, "could not prepare the shot", t)
    null
}

/** ML Kit standing in for iOS document detection: a page is a shot with real printed text. */
private suspend fun looksLikeAPage(context: Context, photo: File): Boolean =
    suspendCancellableCoroutine { cont ->
        try {
            val image = InputImage.fromFilePath(context, android.net.Uri.fromFile(photo))
            TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
                .process(image)
                .addOnSuccessListener { text ->
                    val lines = text.textBlocks.sumOf { it.lines.size }
                    if (cont.isActive) cont.resume(lines >= 3 && text.text.length >= 20)
                }
                .addOnFailureListener { if (cont.isActive) cont.resume(false) }
        } catch (t: Throwable) {
            if (cont.isActive) cont.resume(false)
        }
    }

/**
 * Preview + still capture, torch, pinch zoom and the wide-angle toggle — the
 * slice of the OCR camera this screen needs, with pause/resume so the model
 * gets the whole phone while it thinks.
 */
private class WhatsThisCamera(context: Context) {
    private val appContext = context.applicationContext
    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private val imageCapture = ImageCapture.Builder()
        .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
        .build()

    private val _torchOn = MutableStateFlow(false)
    val torchOn: StateFlow<Boolean> = _torchOn.asStateFlow()
    private val _zoomRatio = MutableStateFlow(1f)
    val zoomRatio: StateFlow<Float> = _zoomRatio.asStateFlow()
    private val _hasUltraWide = MutableStateFlow(false)
    val hasUltraWide: StateFlow<Boolean> = _hasUltraWide.asStateFlow()
    private val _isUltraWide = MutableStateFlow(false)
    val isUltraWide: StateFlow<Boolean> = _isUltraWide.asStateFlow()

    fun start(owner: LifecycleOwner, previewView: PreviewView) {
        val future = ProcessCameraProvider.getInstance(appContext)
        future.addListener({
            val p = future.get()
            provider = p
            imageCapture.targetRotation = previewView.display?.rotation ?: Surface.ROTATION_0
            val preview = Preview.Builder().build()
                .also { it.setSurfaceProvider(previewView.surfaceProvider) }
            try {
                p.unbindAll()
                camera = p.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, imageCapture)
                val minZoom = camera?.cameraInfo?.zoomState?.value?.minZoomRatio ?: 1f
                _hasUltraWide.value = minZoom < 1f
                if (_isUltraWide.value) setZoom(minZoom) else setZoom(_zoomRatio.value)
                if (_torchOn.value) camera?.cameraControl?.enableTorch(true)
            } catch (e: Exception) {
                Log.e(TAG, "camera bind failed", e)
            }
        }, ContextCompat.getMainExecutor(appContext))
    }

    /** Unbind while the model runs; the frozen photo covers the gap. */
    fun pause() {
        provider?.unbindAll()
        camera = null
    }

    fun resume(owner: LifecycleOwner, previewView: PreviewView) {
        if (camera == null) start(owner, previewView)
    }

    fun stop() {
        setTorch(false)
        provider?.unbindAll()
        provider = null
        camera = null
        _zoomRatio.value = 1f
        _isUltraWide.value = false
    }

    fun setTorch(on: Boolean) {
        camera?.cameraControl?.enableTorch(on)
        _torchOn.value = on
    }

    private fun setZoom(ratio: Float) {
        val cam = camera ?: return
        val zs = cam.cameraInfo.zoomState.value
        val clamped = ratio.coerceIn(zs?.minZoomRatio ?: 1f, zs?.maxZoomRatio ?: 1f)
        cam.cameraControl.setZoomRatio(clamped)
        _zoomRatio.value = clamped
    }

    fun onPinch(scaleFactor: Float) = setZoom(_zoomRatio.value * scaleFactor)

    /** iOS handleToggleCameraZoom: sub-1.0 zoom where the camera exposes it. */
    fun toggleUltraWide() {
        val cam = camera ?: return
        val minZoom = cam.cameraInfo.zoomState.value?.minZoomRatio ?: 1f
        if (minZoom >= 1f) return
        if (_isUltraWide.value) {
            setZoom(1f)
            _isUltraWide.value = false
        } else {
            setZoom(minZoom)
            _isUltraWide.value = true
        }
    }

    suspend fun capture(target: File): Boolean = suspendCancellableCoroutine { cont ->
        if (camera == null) {
            cont.resume(false)
            return@suspendCancellableCoroutine
        }
        val options = ImageCapture.OutputFileOptions.Builder(target).build()
        imageCapture.takePicture(
            options,
            ContextCompat.getMainExecutor(appContext),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(result: ImageCapture.OutputFileResults) {
                    if (cont.isActive) cont.resume(true)
                }
                override fun onError(exc: ImageCaptureException) {
                    Log.e(TAG, "capture failed", exc)
                    if (cont.isActive) cont.resume(false)
                }
            },
        )
    }
}

/** Hold-to-ask microphone: on-device speech recognition, started on press, read on release. */
private class AskListener(private val context: Context) {
    private var recognizer: SpeechRecognizer? = null
    private var pending: CompletableDeferred<String>? = null
    private var partial = ""

    val available: Boolean get() = SpeechRecognizer.isRecognitionAvailable(context)

    fun start() {
        destroy()
        partial = ""
        val result = CompletableDeferred<String>()
        pending = result
        val r = SpeechRecognizer.createSpeechRecognizer(context)
        recognizer = r
        r.setRecognitionListener(object : RecognitionListener {
            override fun onResults(results: Bundle?) {
                val heard = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                result.complete(heard ?: partial)
            }
            override fun onPartialResults(partialResults: Bundle?) {
                partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()?.let { partial = it }
            }
            override fun onError(error: Int) {
                Log.w(TAG, "speech recognizer error $error")
                result.complete(partial)
            }
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        r.startListening(
            Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
            }
        )
    }

    suspend fun stopAndTranscribe(): String {
        recognizer?.stopListening()
        val heard = withTimeoutOrNull(6_000) { pending?.await() } ?: partial
        destroy()
        return heard
    }

    fun destroy() {
        recognizer?.destroy()
        recognizer = null
        pending = null
    }
}
