package com.mattmacosko.realtimeaicam.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
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
import androidx.compose.material.icons.filled.Hearing
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material3.Switch
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material.icons.filled.Timer
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
import androidx.compose.ui.res.stringResource
import com.mattmacosko.realtimeaicam.AppLang
import com.mattmacosko.realtimeaicam.R
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.mattmacosko.realtimeaicam.camera.OcrPipeline
import com.mattmacosko.realtimeaicam.camera.ReadingMode
import com.mattmacosko.realtimeaicam.translation.ReaderChoice
import com.mattmacosko.realtimeaicam.translation.ReaderLanguages

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
fun OcrScreen(isSpanish: Boolean, onBack: () -> Unit, onSwitchReader: (translating: Boolean) -> Unit = {}) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    val pipeline = remember { OcrPipeline(context, isSpanish) }
    val activity = remember(context) {
        var c: Context? = context
        while (c is android.content.ContextWrapper && c !is android.app.Activity) c = c.baseContext
        c as? android.app.Activity
    }
    // Test builds only: `-e readTestImage page.png` reads that picture (pushed to the app's
    // external files folder) instead of the camera, so a language can be checked on an emulator.
    LaunchedEffect(Unit) {
        val debuggable = (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val name = activity?.intent?.getStringExtra("readTestImage")
        if (debuggable && !name.isNullOrBlank()) {
            pipeline.testImage = withContext(Dispatchers.IO) {
                android.graphics.BitmapFactory.decodeFile(java.io.File(context.getExternalFilesDir(null), name).path)
            }
        }
    }
    val previewView = remember {
        PreviewView(context).apply {
            scaleType = PreviewView.ScaleType.FILL_CENTER
            // Screen stays awake while this camera view is on screen (AppleVis user LaBoheme,
            // 2026-11-07: auto-lock locked the phone mid-task). Android clears it on its own
            // when the view leaves the screen or the app goes to the background.
            keepScreenOn = true
        }
    }

    DisposableEffect(lifecycleOwner) {
        pipeline.start(lifecycleOwner, previewView)
        onDispose { pipeline.shutdown() }
    }
    // The language pill just switched modes: say the new choice from this screen.
    // Otherwise, opened from home: "Point the camera at some text", once, unless text is already
    // found or being read by then (first-time-user test, 2026-11-04: a few seconds of silence).
    var readHintDone by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        val pillLine = ReaderChoice.pendingAnnouncement
        if (pillLine != null) {
            ReaderChoice.pendingAnnouncement = null
            pipeline.speaker.speak(pillLine)
        }
        if (readHintDone) return@LaunchedEffect
        readHintDone = true
        if (pillLine != null) return@LaunchedEffect
        kotlinx.coroutines.delay(com.mattmacosko.realtimeaicam.camera.UiCue.READ_HINT_DELAY_MS)
        if (com.mattmacosko.realtimeaicam.camera.UiCue.shouldSayReadHint(
                hasText = pipeline.recognizedText.value.isNotBlank() || pipeline.notice.value != null,
                speaking = pipeline.isSpeaking.value,
                openedByLanguagePill = false,
            )
        ) {
            pipeline.speaker.cue(com.mattmacosko.realtimeaicam.camera.UiCue.READ_HINT)
        }
    }

    val text by pipeline.recognizedText.collectAsState()
    val translated by pipeline.translatedText.collectAsState()
    val translating by pipeline.isTranslating.collectAsState()
    val showPopup by pipeline.showTranslationPopup.collectAsState()
    val torchOn by pipeline.torchOn.collectAsState()
    val zoom by pipeline.zoomRatio.collectAsState()
    val isSpeaking by pipeline.isSpeaking.collectAsState()
    val sourceLang by pipeline.sourceLanguage.collectAsState()
    val notice by pipeline.notice.collectAsState()
    val readingMode by pipeline.readingMode.collectAsState()
    val readerOffer by pipeline.readerOffer.collectAsState()
    val readerDownloading by pipeline.readerDownloading.collectAsState()
    // Your language: the pill names where the page goes ("French → Spanish").
    val ylReady by com.mattmacosko.realtimeaicam.translation.YourLanguage.readyPacks.collectAsState()
    val ylChoice by com.mattmacosko.realtimeaicam.translation.YourLanguage.choice.collectAsState()
    val outputLang = remember(ylReady, ylChoice) { pipeline.outputLanguage() }

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
                .liveSafePadding(horizontal = true)
                .padding(top = 40.dp, start = 20.dp, end = 20.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.Top,
        ) {
            BackPill(onBack)
            // One Read screen (Read + Translate merged, iOS parity 2026-11-03): the pill
            // picks English, or a language to translate into English. Remembered.
            LanguagePill(
                index = ReaderChoice.indexOf(isSpanish, sourceLang),
                target = outputLang,
                onSelect = { i ->
                    val translating = i > 0
                    ReaderChoice.remember(context, translating)
                    if (translating) pipeline.setSourceLanguage(ReaderLanguages.all[i - 1])
                    // In the app's language: an app line, said in a voice for it.
                    val spoken = ReaderChoice.pillSpoken(
                        if (i > 0) ReaderLanguages.all[i - 1] else null, outputLang)
                    if (translating == isSpanish) {
                        pipeline.speaker.speak(spoken)
                    } else {
                        // The other mode's screen says it once it is up.
                        ReaderChoice.pendingAnnouncement = spoken
                        onSwitchReader(translating)
                    }
                },
            )
        }

        // Can't be heard? Say why, under the top bar (2026-11-04).
        SpeechProblemBanner(
            pipeline.speaker,
            Modifier
                .align(Alignment.TopCenter)
                .liveSafePadding(horizontal = true)
                .padding(top = 100.dp, start = 20.dp, end = 20.dp),
        )

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
            visible = text.isNotEmpty() || notice != null,
            enter = slideInVertically(tween(250)) { it / 2 } + fadeIn(tween(250)),
            exit = slideOutVertically(tween(200)) { it / 2 } + fadeOut(tween(200)),
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .liveSafePadding(horizontal = true, bottom = true, navOnly = true)
                .padding(bottom = 122.dp, start = 20.dp, end = 20.dp),
        ) {
            val displayText = notice ?: translated ?: text
            val isTranslationShown = translated != null && notice == null
            val cardHeading = when {
                !isSpanish -> stringResource(R.string.f_detected)
                readerOffer || readerDownloading -> stringResource(R.string.f_reader_heading, sourceLang.nameInSentence)
                notice != null -> stringResource(R.string.f_language_pack)
                isTranslationShown -> stringResource(R.string.f_translation)
                else -> stringResource(R.string.f_text_heading, sourceLang.nameInSentence)
            }
            val cardTappable = isSpanish && (isTranslationShown || readerOffer)
            val cardClickLabel = if (readerOffer) stringResource(R.string.f_card_download, sourceLang.nameInSentence)
                else stringResource(R.string.f_card_actions)
            val onCardTap = {
                // The reader downloads only on this tap, never when the pill passes by.
                if (readerOffer) pipeline.downloadReader(activity)
                else pipeline.showTranslationPopup.value = true
            }
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(IosColors.Material.copy(alpha = 0.90f), RoundedCornerShape(16.dp))
                    // Only a card that does something is a button. A plain reading card was a
                    // disabled clickable, heard as "button, disabled" (2026-11-04).
                    .then(
                        if (cardTappable) Modifier.clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClickLabel = cardClickLabel,
                            onClick = onCardTap,
                        ) else Modifier
                    )
                    .padding(16.dp)
                    // Read as one block, once: a status dot, a heading and a scrolling body are
                    // three separate stops otherwise, and a merged label on top of the merged
                    // text read the letter twice (2026-11-04). The tap stays an action.
                    .clearAndSetSemantics {
                        contentDescription = OcrCardSemantics.label(cardHeading, displayText)
                        testTag = "readTextCard"
                        if (cardTappable) {
                            role = Role.Button
                            onClick(label = cardClickLabel) { onCardTap(); true }
                        }
                    },
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
                        cardHeading,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                        color = Color.White.copy(alpha = 0.9f),
                    )
                    Spacer(Modifier.weight(1f))
                    if (translating || readerDownloading) AnimatedLoader(22.dp)
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
                .liveSafePadding(horizontal = true, bottom = true, navOnly = true)
                .padding(bottom = 32.dp, start = 20.dp, end = 20.dp),
        ) {
            // 1. Settings
            CircleControlButton(
                label = stringResource(R.string.f_settings),
                clickLabel = stringResource(R.string.f_settings_click_read),
                onClick = { showSettings = true },
            ) {
                Icon(Icons.Default.Settings, null, tint = Color.White, modifier = Modifier.size(22.dp))
            }
            // 2. Torch — one tap on at full brightness, one tap off (same as What's This).
            // The 25/50/75/100 menu is gone: picking a percentage before any light
            // appears costs screen-reader flicks at the moment you cannot see.
            CircleControlButton(
                ringColor = if (torchOn) IosColors.Yellow.copy(alpha = 0.5f) else Color.White.copy(alpha = 0.2f),
                label = stringResource(R.string.f_flashlight),
                stateLabel = stringResource(if (torchOn) R.string.f_torch_on_state else R.string.f_torch_off_state),
                clickLabel = stringResource(if (torchOn) R.string.f_torch_turn_off else R.string.f_torch_turn_on),
                onClick = { pipeline.setTorch(!torchOn) },
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
                CircleControlButton(
                    label = stringResource(R.string.f_translate),
                    stateLabel = if (translating) stringResource(R.string.f_translating) else null,
                    clickLabel = stringResource(
                        R.string.f_translate_click, sourceLang.nameInSentence,
                        com.mattmacosko.realtimeaicam.translation.LanguageNames.inSentence(outputLang),
                    ),
                    onClick = { if (debouncer.tryFire()) pipeline.translate() },
                ) {
                    Icon(
                        Icons.Default.Translate,
                        null,
                        tint = Color.White.copy(alpha = if (translating) 0.6f else 1f),
                        modifier = Modifier.size(22.dp),
                    )
                }
            } else {
                CircleControlButton(
                    label = stringResource(R.string.f_copy_text),
                    clickLabel = stringResource(R.string.f_copy_text_click),
                    onClick = {
                        val t = translated ?: text
                        if (t.isNotBlank()) copyToClipboard(context, t)
                    },
                ) {
                    Icon(Icons.Default.ContentCopy, null, tint = Color.White, modifier = Modifier.size(22.dp))
                }
            }
            // 4. Speak — green fill ONLY while TTS audio is actually playing
            // (iOS speakButton: Color.green.opacity(0.3) when isSpeaking)
            CircleControlButton(
                fillColor = if (isSpeaking) IosColors.Green.copy(alpha = 0.30f)
                else Color.Black.copy(alpha = 0.32f),
                label = stringResource(if (isSpeaking) R.string.f_stop_reading else R.string.f_read_aloud),
                stateLabel = stringResource(if (isSpeaking) R.string.f_speaking else R.string.f_not_speaking),
                clickLabel = stringResource(if (isSpeaking) R.string.f_stop_speaking else R.string.f_speak_found),
                onClick = {
                    if (debouncer.tryFire()) pipeline.speakCurrent()
                },
            ) {
                Icon(Icons.Default.RecordVoiceOver, null, tint = Color.White, modifier = Modifier.size(22.dp))
            }
            // 4b. Reading mode — Tap to read / Auto read / Mute (Matt, 2026-10-23). Each tap steps
            // to the next mode and says its name; the choice is remembered.
            ReadingModeButton(
                mode = readingMode,
                onClick = { if (debouncer.tryFire()) pipeline.cycleReadingMode() },
            )
            // 5. Reset
            CircleControlButton(
                label = stringResource(R.string.f_clear_stop),
                clickLabel = stringResource(R.string.f_clear_stop_click_read),
                onClick = { pipeline.reset() },
            ) {
                Icon(Icons.Default.Refresh, null, tint = Color.White, modifier = Modifier.size(22.dp))
            }
        }

        // Tap anywhere outside the torch popup to dismiss it
        if (showTorchPopup && !torchOn) {
            val closeTorch = stringResource(R.string.f_torch_brightness_close)
            Box(
                Modifier
                    .fillMaxSize()
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClickLabel = stringResource(R.string.f_torch_choices_close),
                    ) { showTorchPopup = false }
                    .semantics { contentDescription = closeTorch }
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
                .liveSafePadding(horizontal = true, bottom = true, navOnly = true)
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
                    val presetLabel = stringResource(R.string.f_torch_percent, preset)
                    val selectedLabel = stringResource(if (selected) R.string.f_selected else R.string.f_not_selected)
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
                            .clickable(role = Role.Button) {
                                torchPreset = preset
                                pipeline.setTorch(true)
                                showTorchPopup = false
                            }
                            .semantics(mergeDescendants = true) {
                                contentDescription = presetLabel
                                stateDescription = selectedLabel
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

/**
 * The small reading-mode button beside Speak. TalkBack hears "Reading mode, Auto read" and
 * "double tap to switch to Mute"; the app also says the new mode's name when it changes.
 */
@Composable
private fun ReadingModeButton(mode: ReadingMode, onClick: () -> Unit) {
    val auto = mode == ReadingMode.AUTO
    CircleControlButton(
        fillColor = if (auto) IosColors.Blue.copy(alpha = 0.30f) else Color.Black.copy(alpha = 0.32f),
        ringColor = if (auto) IosColors.Blue.copy(alpha = 0.6f) else Color.White.copy(alpha = 0.2f),
        label = stringResource(R.string.f_reading_mode, mode.label),
        clickLabel = stringResource(R.string.f_switch_to, mode.next.label),
        onClick = onClick,
    ) {
        Icon(
            when (mode) {
                ReadingMode.TAP -> Icons.Default.TouchApp
                ReadingMode.AUTO -> Icons.Default.Hearing
                ReadingMode.MUTE -> Icons.Default.VolumeOff
            },
            null,
            tint = Color.White,
            modifier = Modifier.size(20.dp),
        )
    }
}

/** Translation Ready popup (spec §3.5). */
@Composable
private fun TranslationActionsPopup(
    onCopy: () -> Unit,
    onContinue: () -> Unit,
    onNewScan: () -> Unit,
) {
    val closeOptions = stringResource(R.string.f_close_translation_options)
    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.4f))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClickLabel = stringResource(R.string.f_close_keep_reading),
                onClick = onContinue,
            )
            .semantics { contentDescription = closeOptions },
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
                stringResource(R.string.f_translation_ready),
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color.White,
                modifier = Modifier.padding(bottom = 8.dp),
            )
            PopupActionButton(stringResource(R.string.f_copy_translation), Icons.Default.ContentCopy, IosColors.Blue, onCopy)
            PopupActionButton(stringResource(R.string.f_continue_reading), Icons.Default.Visibility, IosColors.Green, onContinue)
            PopupActionButton(stringResource(R.string.f_new_scan), Icons.Default.Refresh, IosColors.Orange, onNewScan)
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
            .clickable(role = Role.Button, onClick = onClick)
            .padding(vertical = 14.dp)
            .clearAndSetSemantics { contentDescription = label },
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
fun SettingsOverlay(zoom: Float, onDismiss: () -> Unit, fromHome: Boolean = false) {
    val context = LocalContext.current
    var history by remember { mutableStateOf(CopyHistory.get(context)) }
    val prefs = remember { context.getSharedPreferences("rtcam", Context.MODE_PRIVATE) }
    var countdownEnabled by remember { mutableStateOf(prefs.getBoolean("countdownBeforeCapture", true)) }
    var speakAloud by remember { mutableStateOf(prefs.getBoolean("speakAnswersAloud", true)) }
    // Says the Your language choice and the download progress (kept for the app's life, so
    // "ready" is still said after Settings is closed).
    val settingsVoice = remember { AppVoice.get(context) }
    val closeSettings = stringResource(R.string.f_close_settings)
    val countdownTitle = stringResource(R.string.f_countdown_title)
    val ownVoiceTitle = stringResource(R.string.f_own_voice_title)
    val clearHistory = stringResource(R.string.f_clear_history)
    val copySaved = stringResource(R.string.f_copy_saved)

    Box(
        Modifier
            .fillMaxSize()
            // From home (Settings pill, 2026-11-03) it covers the busy home art.
            .background(Color.Black.copy(alpha = if (fromHome) 0.75f else 0.4f))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClickLabel = closeSettings,
                onClick = onDismiss,
            )
            .semantics { contentDescription = closeSettings },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .widthIn(max = 380.dp)
                .fillMaxWidth(0.92f)
                .heightIn(max = 600.dp)
                .clip(RoundedCornerShape(20.dp))
                .background(if (fromHome) Color(0xFF1E1E1E) else Color(0xE61E1E1E), RoundedCornerShape(20.dp))
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
                Text(stringResource(R.string.f_settings), fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                Spacer(Modifier.weight(1f))
                Text(
                    "✕",
                    fontSize = 20.sp,
                    color = IosColors.Gray,
                    modifier = Modifier
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            role = Role.Button,
                            onClick = onDismiss,
                        )
                        .padding(4.dp)
                        .semantics { contentDescription = closeSettings },
                )
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.15f)))

            Column(
                Modifier
                    .verticalScroll(rememberScrollState())
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                // 1.24: which What's this? model answers.
                ModelsCard()

                // Your language (2026-11-04): what results are spoken in.
                YourLanguageSettingsCard(say = { settingsVoice.speak(it) })

                // Countdown before the photo — asked for on AppleVis by Dennis.
                SettingsCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Timer, null, tint = IosColors.Purple, modifier = Modifier.size(20.dp))
                        Column(Modifier.weight(1f).padding(start = 8.dp)) {
                            Text(countdownTitle, fontSize = 17.sp,
                                fontWeight = FontWeight.SemiBold, color = Color.White)
                            Text(
                                stringResource(R.string.f_countdown_desc),
                                fontSize = 12.sp, color = IosColors.Gray,
                            )
                        }
                        Switch(
                            checked = countdownEnabled,
                            onCheckedChange = {
                                countdownEnabled = it
                                prefs.edit().putBoolean("countdownBeforeCapture", it).apply()
                            },
                            modifier = Modifier.semantics {
                                contentDescription = countdownTitle
                            },
                        )
                    }
                }

                // Let the screen reader do the talking — asked for by Cash.
                SettingsCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.VolumeUp, null, tint = IosColors.Blue, modifier = Modifier.size(20.dp))
                        Column(Modifier.weight(1f).padding(start = 8.dp)) {
                            Text(ownVoiceTitle, fontSize = 17.sp,
                                fontWeight = FontWeight.SemiBold, color = Color.White)
                            Text(
                                stringResource(R.string.f_own_voice_desc),
                                fontSize = 12.sp, color = IosColors.Gray,
                            )
                        }
                        Switch(
                            checked = speakAloud,
                            onCheckedChange = {
                                speakAloud = it
                                prefs.edit().putBoolean("speakAnswersAloud", it).apply()
                            },
                            modifier = Modifier.semantics {
                                contentDescription = ownVoiceTitle
                            },
                        )
                    }
                }

                // Copy History
                SettingsCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Default.ContentCopy, null,
                            tint = IosColors.Orange, modifier = Modifier.size(20.dp),
                        )
                        Text(
                            "  " + stringResource(R.string.f_copy_history), fontSize = 17.sp,
                            fontWeight = FontWeight.SemiBold, color = Color.White,
                        )
                        Spacer(Modifier.weight(1f))
                        if (history.isNotEmpty()) {
                            Text(
                                stringResource(R.string.f_clear), fontSize = 12.sp, color = IosColors.Red,
                                modifier = Modifier
                                    .clickable(
                                        role = Role.Button,
                                        onClickLabel = stringResource(R.string.f_clear_history_click),
                                    ) {
                                        CopyHistory.clear(context)
                                        history = emptyList()
                                    }
                                    .semantics { contentDescription = clearHistory },
                            )
                        }
                    }
                    if (history.isEmpty()) {
                        Text(
                            stringResource(R.string.f_no_copies),
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
                                        .clickable(role = Role.Button) { copyToClipboard(context, item) }
                                        .semantics { contentDescription = copySaved },
                                )
                            }
                        }
                    }
                }

                // Camera Zoom (only when zoomed)
                if (!fromHome && (zoom < 0.95f || zoom > 1.05f)) {
                    SettingsCard {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("🔍", fontSize = 18.sp, modifier = Modifier.clearAndSetSemantics { })
                            Text(
                                "  " + stringResource(R.string.f_camera_zoom), fontSize = 17.sp,
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

                // Tips: camera-screen controls; from home they would point at
                // controls that aren't there (iOS parity, 2026-11-03).
                if (!fromHome) SettingsCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("ℹ️", fontSize = 18.sp, modifier = Modifier.clearAndSetSemantics { })
                        Text(
                            "  " + stringResource(R.string.f_tips), fontSize = 17.sp,
                            fontWeight = FontWeight.SemiBold, color = Color.White,
                        )
                    }
                    TipLine("• 🤏 " + stringResource(R.string.f_tip_pinch))
                    TipLine("• 📋 " + stringResource(R.string.f_tip_copy))
                    TipLine("• 🔁 " + stringResource(R.string.f_tip_reset))
                    TipLine("• 🗣️ " + stringResource(R.string.f_tip_speak))
                    TipLine("• 👂 " + stringResource(R.string.f_tip_mode))
                    TipLine("• 🔦 " + stringResource(R.string.f_tip_torch))
                    TipLine("• ⚙️ " + stringResource(R.string.f_tip_settings))
                }

                // Private by Design
                SettingsCard(extraStroke = true) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("🔒", fontSize = 18.sp, modifier = Modifier.clearAndSetSemantics { })
                        Text(
                            "  " + stringResource(R.string.f_private_design), fontSize = 17.sp,
                            fontWeight = FontWeight.SemiBold, color = IosColors.Green,
                        )
                    }
                    TipLine("✈️ " + stringResource(R.string.f_priv_offline))
                    TipLine("🙈 " + stringResource(R.string.f_priv_tracking))
                    TipLine("📷 " + stringResource(R.string.f_priv_camera))
                    TipLine("📋 " + stringResource(R.string.f_priv_history))
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
    Text(
        text, fontSize = 13.sp, color = IosColors.Secondary, lineHeight = 19.sp,
        modifier = Modifier.semantics { contentDescription = text.withoutEmoji() },
    )
}


/**
 * The Read language pill (2026-09-21 "Translate from", merged with English 2026-11-03).
 * A screen reader hears one button, "Language, English" or "Language, Spanish, translated
 * to English"; a double tap or a sighted tap steps to the next choice, wrapping back to
 * English, and TalkBack's actions menu has "Previous language".
 */
@Composable
private fun LanguagePill(index: Int, target: String = "en", onSelect: (Int) -> Unit) {
    val count = ReaderChoice.count
    val i = index.coerceIn(0, count - 1)
    val page = if (i > 0) ReaderLanguages.all[i - 1] else null
    // In the app's language: "Francés → Ing" on screen, "Francés, traducido al inglés" in TalkBack.
    val pillText = ReaderChoice.pillLabel(page, target)
    val pillSpoken = ReaderChoice.pillSpoken(page, target)
    val changeLabel = stringResource(R.string.f_change)
    val previousLabel = stringResource(R.string.f_previous_language)
    val next = { onSelect(ReaderChoice.next(i)) }
    Row(
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(IosColors.Material.copy(alpha = 0.85f), RoundedCornerShape(20.dp))
            .clickable { next() }
            .padding(horizontal = 12.dp, vertical = 10.dp)
            // A button, not a slider (first-time-user test, 2026-11-04: "Language, slider"
            // didn't match what it looks like): "Language, English, button, double tap to change".
            // Going back one is an action in TalkBack's actions menu.
            .clearAndSetSemantics {
                contentDescription = OcrCardSemantics.languageLabel(pillSpoken)
                role = Role.Button
                testTag = "readLanguagePill"
                onClick(label = changeLabel) { next(); true }
                customActions = listOf(
                    androidx.compose.ui.semantics.CustomAccessibilityAction(previousLabel) {
                        onSelect(ReaderChoice.previous(i)); true
                    },
                )
            },
    ) {
        Text("🌍", fontSize = 14.sp)
        Text(
            pillText,
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
            color = Color.White,
            maxLines = 1,
        )
    }
}


/** The spoken words of Read's text card and language pill, kept apart so they can be unit tested. */
object OcrCardSemantics {
    /** "Detected. <the text>": the heading, then the text, each once. */
    fun label(heading: String, text: String): String = if (text.isBlank()) heading else "$heading. $text"

    /** "Language, English" / "Idioma, Inglés" (TalkBack adds "button, double tap to change"). */
    fun languageLabel(spoken: String): String = AppLang.str(R.string.f_language_label, spoken)
}
