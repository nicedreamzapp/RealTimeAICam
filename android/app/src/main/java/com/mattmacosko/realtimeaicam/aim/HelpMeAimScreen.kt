package com.mattmacosko.realtimeaicam.aim

import com.mattmacosko.realtimeaicam.ui.liveSafePadding
import com.mattmacosko.realtimeaicam.ui.withoutEmoji
import androidx.compose.ui.semantics.clearAndSetSemantics
import android.content.Context
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.res.stringResource
import com.mattmacosko.realtimeaicam.AppLang
import com.mattmacosko.realtimeaicam.R
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.mattmacosko.realtimeaicam.camera.SpeechAnnouncer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.withContext

/**
 * Help Me Aim, Android.
 *
 * This screen is a deliberate match for the iPhone's `HelpMeAimView.swift`:
 * the SAME four phases (choosing, asking, aiming, taken), the same buttons in
 * the same order with the same emoji, colours, titles and hints, the same top
 * bar, and the same spoken words. Matt, 2026-09-20: "look at the way the
 * iPhone is ... and compare them and make it right."
 *
 * If a control is added to one phone, add it to the other in the same place.
 */
private enum class AimPhase { CHOOSING, ASKING, AIMING, TAKEN }

/** The iOS system colours the iPhone screen uses, so both look like one app. */
private val IosPink = Color(0xFFFF2D55)
private val IosBlue = Color(0xFF007AFF)
private val IosOrange = Color(0xFFFF9500)
private val IosGreen = Color(0xFF34C759)
private val IosGray = Color(0xFF8E8E93)
private val IosPurple = Color(0xFFBF5AF2)
private val IosRed = Color(0xFFFF453A)

@Composable
fun HelpMeAimScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()

    // Your language (2026-11-04): guidance and the description are said in it once its pack is on
    // the phone; the finder's word matching stays English inside.
    val speaker = remember {
        SpeechAnnouncer(context).also {
            it.setEnabled(true)
            it.localizeTo = com.mattmacosko.realtimeaicam.translation.YourLanguage.code(context)
        }
    }
    // Spanish app (2026-11-05): object names inside the app's Spanish lines go through Your
    // language's translator once (never on the main thread, never a download). See AimNames.
    remember {
        AimNames.translate = { text, lang ->
            if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
                null
            } else {
                com.mattmacosko.realtimeaicam.translation.YourLanguage.translateBlocking(text, "en", lang)
            }
        }
    }
    val pipeline = remember { AimPipeline(context, speaker) }
    val listener = remember { AimListener(context) }
    val previewView = remember {
        PreviewView(context).apply {
            scaleType = PreviewView.ScaleType.FIT_CENTER
            // Screen stays awake while this camera view is on screen (AppleVis user LaBoheme,
            // 2026-11-07: auto-lock locked the phone mid-task). Android clears it on its own
            // when the view leaves the screen or the app goes to the background.
            keepScreenOn = true
        }
    }

    var phase by remember { mutableStateOf(AimPhase.CHOOSING) }
    var subject by remember { mutableStateOf<AimSubject?>(null) }
    var status by remember { mutableStateOf("") }
    var typed by remember { mutableStateOf("") }
    var listening by remember { mutableStateOf(false) }
    var recent by remember { mutableStateOf(AimRecent.load(context)) }

    // Test builds only: `-e aimPreviewTaken true` opens Picture Taken with a
    // long description, so a phone check needs no camera aiming (2026-11-03).
    var previewPhoto by remember { mutableStateOf<android.graphics.Bitmap?>(null) }
    var fakeStart by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        val debuggable = (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        var c: Context? = context
        while (c is android.content.ContextWrapper && c !is android.app.Activity) c = c.baseContext
        val activity = c as? android.app.Activity
        val fakeWord = activity?.intent?.getStringExtra("aimFakeFind")
        if (debuggable && !fakeWord.isNullOrBlank()) {
            AimFake.setUp(context, fakeWord)
            fakeStart = fakeWord
        }
        if (debuggable && activity?.intent?.getStringExtra("aimPreviewTaken") == "true") {
            previewPhoto = android.graphics.Bitmap.createBitmap(1200, 900, android.graphics.Bitmap.Config.ARGB_8888)
                .apply { eraseColor(android.graphics.Color.DKGRAY) }
            status = List(5) {
                "A soft white stuffed bunny with long floppy ears sits on a wooden table next to a blue mug, a pair of glasses and a stack of mail."
            }.joinToString(" ") + " END OF DESCRIPTION. Saved to your photos with its description."
            phase = AimPhase.TAKEN
        }
    }

    val spoken by pipeline.spoken.collectAsState()
    val countdownWord by pipeline.countdownWord.collectAsState()
    val lastPhoto by pipeline.lastPhoto.collectAsState()
    val done by pipeline.done.collectAsState()
    val torchOn by pipeline.torchOn.collectAsState()
    val isFront by pipeline.isFront.collectAsState()

    // Declared in the manifest, but Android still has to be asked at the moment
    // of use. Without this the recognizer fails instantly and the prompt
    // flashes past — which is what it did on Matt's phone, 2026-09-20.
    var micAllowed by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(
                context, android.Manifest.permission.RECORD_AUDIO,
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED,
        )
    }
    var askAfterPermission by remember { mutableStateOf(false) }
    val micLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        micAllowed = granted
        if (!granted) {
            status = AppLang.str(R.string.g_aim_mic_denied)
            speaker.speak(status)
        }
    }

    DisposableEffect(Unit) {
        pipeline.loadDetector()
        onDispose {
            pipeline.shutdown()
            listener.close()
            speaker.shutdown()
            AimNames.translate = null
        }
    }

    fun beginAiming(s: AimSubject) {
        subject = s
        phase = AimPhase.AIMING
        pipeline.aimAt(s)
        pipeline.start(owner, previewView)
        scope.launch {
            // The object's name in the app's language before the first line is said.
            withContext(kotlinx.coroutines.Dispatchers.IO) { AimNames.warm(s) }
            val intro = if (s is AimSubject.Described) AimAsk.intro(s.word, pipeline.lookSeconds()) else AimPhrases.intro(s)
            speaker.speakAndWait(intro, timeoutMs = 9000)
        }
    }

    fun backToChoices() {
        pipeline.setTorch(false)
        pipeline.stop()
        subject = null
        status = ""
        typed = ""
        phase = AimPhase.CHOOSING
    }

    /** [word] in English for the finder; [asked] is what the person typed or said. */
    fun findTyped(word: String, asked: String = word) {
        val match = AimVocabulary.match(word, pipeline.classNames)
        val said = AimVocabulary.normalize(word)
        if (match == null && said.isNotBlank() && pipeline.canDescribe()) {
            // No name for it in the finder: the describing model looks instead.
            beginAiming(AimSubject.Described(said))
        } else if (match == null) {
            // A Spanish app repeats the person's own word, not the finder's English for it.
            status = AimPhrases.cantLookFor(if (AppLang.isSpanish) asked else AimVocabulary.normalize(word))
            speaker.speak(status)
        } else {
            beginAiming(AimSubject.Obj(match))
        }
    }

    /**
     * What the person typed or said, in Your language, put into English first so the finder's
     * English word list (AimVocabulary, AimAsk) can match it: "taza" -> "cup".
     */
    fun findInYourLanguage(word: String) {
        val lang = speaker.outputLanguage()
        if (lang == "en") { findTyped(word); return }
        scope.launch {
            val english = withContext(kotlinx.coroutines.Dispatchers.IO) {
                AimInput.toEnglish(word, lang) { w, from ->
                    com.mattmacosko.realtimeaicam.translation.YourLanguage.translateBlocking(w, from, "en")
                }
            }
            android.util.Log.i("HelpMeAim", "target [$lang] \"$word\" -> \"$english\" -> ${AimVocabulary.match(english, pipeline.classNames)}")
            findTyped(english, word)
        }
    }

    LaunchedEffect(fakeStart) {
        val w = fakeStart ?: return@LaunchedEffect
        delay(2000)
        findInYourLanguage(w)
    }

    /** Ask, beep, listen, look it up — the iPhone's Something Else flow. */
    fun listen() {
        if (!micAllowed) {
            askAfterPermission = true
            micLauncher.launch(android.Manifest.permission.RECORD_AUDIO)
            return
        }
        scope.launch {
            listening = true
            status = AimPhrases.askWhat
            speaker.speakAndWait(AimPhrases.askWhat, timeoutMs = 4000)
            delay((AimListening.afterPrompt * 1000).toLong())
            // Two rising notes so there is no doubt when to talk, two falling
            // ones when it stops. Matt asked for this on the iPhone.
            AimBeep.play(context, AimTones.start)
            delay((AimTones.duration * 1000).toLong())
            val heard = listener.listen(speaker.outputLanguage())
            AimBeep.play(context, AimTones.end)
            listening = false
            val result = AimListening.result(heard ?: "", failed = heard == null)
            if (result is AimListening.Result.Heard) {
                findInYourLanguage(result.transcript)
            } else {
                status = AimListening.reply(result) ?: AimPhrases.didntCatch
                speaker.speak(status)
            }
        }
    }

    LaunchedEffect(micAllowed, askAfterPermission) {
        if (micAllowed && askAfterPermission) {
            askAfterPermission = false
            listen()
        }
    }

    // The picture landed: show it, exactly as the iPhone does.
    // The line changes again once the description is read out.
    LaunchedEffect(done) {
        if (done != null && phase == AimPhase.AIMING) {
            status = done ?: ""
            val word = when (val s = subject) {
                is AimSubject.Obj -> s.match.spokenName
                is AimSubject.Described -> s.word
                else -> null
            }
            word?.let {
                recent = AimRecent.updated(recent, it)
                AimRecent.save(context, recent)
            }
            phase = AimPhase.TAKEN
            pipeline.stop()
        } else if (done != null && phase == AimPhase.TAKEN) {
            status = done ?: ""
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        when (phase) {
            AimPhase.CHOOSING -> Choices(
                onBack = { onBack() },
                onFace = { beginAiming(AimSubject.Face) },
                onPage = { beginAiming(AimSubject.Page) },
                onSomethingElse = { phase = AimPhase.ASKING; status = "" },
            )

            AimPhase.ASKING -> Asking(
                status = status,
                listening = listening,
                typed = typed,
                onTyped = { typed = it },
                onListen = { listen() },
                onSubmit = { if (typed.isNotBlank()) findInYourLanguage(typed) },
                onBack = { backToChoices() },
                recent = recent,
                onPickRecent = { findTyped(it) },
                onClearRecent = {
                    recent = emptyList()
                    AimRecent.save(context, recent)
                    speaker.speak(AppLang.str(R.string.g_aim_recent_cleared))
                },
            )

            AimPhase.AIMING -> Aiming(
                previewView = previewView,
                subjectName = subject?.spokenName ?: stringResource(R.string.g_aim_your_subject),
                isFace = subject is AimSubject.Face,
                isFront = isFront,
                torchOn = torchOn,
                countdownWord = countdownWord,
                statusText = spoken,
                onShootNow = { pipeline.shootNow() },
                onBack = { backToChoices() },
                onToggleCamera = { speaker.speak(pipeline.toggleCamera()) },
                onToggleTorch = { speaker.speak(pipeline.toggleTorch()) },
            )

            AimPhase.TAKEN -> Taken(
                photo = lastPhoto ?: previewPhoto,
                statusText = status,
                subjectName = subject?.spokenName ?: stringResource(R.string.g_aim_same_thing),
                onTakeAnother = {
                    val s = subject
                    if (s != null) {
                        pipeline.takeAnother()
                        phase = AimPhase.AIMING
                        pipeline.start(owner, previewView)
                        scope.launch {
                            withContext(kotlinx.coroutines.Dispatchers.IO) { AimNames.warm(s) }
                            speaker.speakAndWait(AimPhrases.intro(s), timeoutMs = 6000)
                        }
                    }
                },
                onBack = { backToChoices() },
            )
        }
        // Can't be heard? Say why (2026-11-04). The beeps play on the same volume.
        com.mattmacosko.realtimeaicam.ui.SpeechProblemBanner(
            speaker,
            Modifier
                .align(Alignment.TopCenter)
                .liveSafePadding(top = true)
                .padding(top = 90.dp, start = 20.dp, end = 20.dp),
        )
    }
}

// MARK: - Pieces, one for one with the iPhone

@Composable
private fun TopBar(title: String, backLabel: String, onBack: () -> Unit) {
    // The title is centred on the SCREEN, not in the space left over beside the
    // back button. Balancing it with a fixed-width spacer (what I tried first)
    // only centres it when the back button happens to be exactly that wide,
    // which it never is.
    Box(
        Modifier.fillMaxWidth().liveSafePadding(top = true).padding(top = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            title,
            color = Color.White,
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
            // Clear of the back pill on both sides, so a longer Spanish title
            // ("Ayúdame a apuntar") wraps instead of running under it.
            modifier = Modifier.fillMaxWidth().padding(horizontal = 100.dp).semantics { heading() },
        )
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterStart) {
            SmallButton(stringResource(R.string.g_aim_back_chevron), backLabel, onBack)
        }
    }
}

/**
 * The iPhone's smallButton: a black capsule with a white outline, not a plain
 * filled button. Used for Back, the camera switch and the flashlight.
 */
@Composable
private fun SmallButton(text: String, label: String, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Box(
        Modifier
            .clip(shape)
            .background(Color.Black.copy(alpha = 0.6f))
            .border(1.5.dp, Color.White.copy(alpha = 0.7f), shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp)
            .clearAndSetSemantics { contentDescription = label.withoutEmoji() },
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
    }
}

/**
 * The iPhone's AimBigButton, matched piece for piece: emoji at 34 and the title
 * in outlined text at 24, CENTRED, 88 tall, corner radius 22, a white-to-colour
 * gradient and two strokes (white 4, colour 2). The hint is spoken, never drawn
 * — showing it made the Android buttons look nothing like the iPhone's.
 */
@Composable
private fun AimBigButton(
    emoji: String,
    title: String,
    color: Color,
    hint: String,
    onClick: () -> Unit,
    label: String? = null,
) {
    val shape = RoundedCornerShape(22.dp)
    Box(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 88.dp)
            .clip(shape)
            .background(
                androidx.compose.ui.graphics.Brush.verticalGradient(
                    listOf(Color.White.copy(alpha = 0.23f), color.copy(alpha = 0.55f)),
                ),
            )
            .border(4.dp, Color.White.copy(alpha = 0.8f), shape)
            .border(2.dp, color, shape)
            .clickable(onClick = onClick)
            .clearAndSetSemantics {
                contentDescription = "${label ?: title}. $hint"
            },
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(emoji, fontSize = 34.sp)
            com.mattmacosko.realtimeaicam.ui.OutlinedText(text = title, fontSize = 24.sp)
        }
    }
}

@Composable
private fun Choices(
    onBack: () -> Unit,
    onFace: () -> Unit,
    onPage: () -> Unit,
    onSomethingElse: () -> Unit,
) {
    Column(
        Modifier.fillMaxSize().liveSafePadding(horizontal = true, bottom = true, navOnly = true).padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        TopBar(stringResource(R.string.g_aim_title), stringResource(R.string.g_aim_back_to_home), onBack)
        Text(
            stringResource(R.string.g_aim_choose_heading),
            color = Color.White,
            fontSize = 22.sp,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().semantics { heading() },
        )
        // iOS puts a Spacer above and below the three buttons, so they sit in
        // the middle of the screen rather than crowding the top.
        Spacer(Modifier.weight(1f))
        AimBigButton(
            "🙂", stringResource(R.string.g_aim_face_title), IosPink,
            stringResource(R.string.g_aim_face_hint), onFace,
        )
        AimBigButton(
            "🖼️", stringResource(R.string.g_aim_page_title), IosBlue,
            stringResource(R.string.g_aim_page_hint), onPage,
        )
        AimBigButton(
            "🔎", stringResource(R.string.g_aim_else_title), IosOrange,
            stringResource(R.string.g_aim_else_hint), onSomethingElse,
        )
        Spacer(Modifier.weight(1f))
    }
}

@Composable
private fun Asking(
    status: String,
    listening: Boolean,
    typed: String,
    onTyped: (String) -> Unit,
    onListen: () -> Unit,
    onSubmit: () -> Unit,
    onBack: () -> Unit,
    recent: List<String> = emptyList(),
    onPickRecent: (String) -> Unit = {},
    onClearRecent: () -> Unit = {},
) {
    Column(
        Modifier.fillMaxSize().liveSafePadding(horizontal = true, bottom = true, navOnly = true).padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        TopBar(stringResource(R.string.g_aim_else_title), stringResource(R.string.g_aim_back_to_choices), onBack)
        Text(
            stringResource(R.string.g_aim_ask_heading),
            color = Color.White,
            fontSize = 22.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.semantics { heading() },
        )
        AimBigButton(
            emoji = if (listening) "\uD83D\uDC42" else "\uD83C\uDF99\uFE0F",
            title = if (listening) stringResource(R.string.g_aim_listening_title) else stringResource(R.string.g_aim_speak_title),
            color = if (listening) IosRed else IosPurple,
            hint = if (listening) stringResource(R.string.g_aim_listening_hint) else stringResource(R.string.g_aim_speak_hint),
            onClick = onListen,
            label = if (listening) stringResource(R.string.g_aim_listening_label) else stringResource(R.string.g_aim_speak_label),
        )
        if (status.isNotEmpty()) {
            Text(
                status,
                color = Color.Yellow,
                fontSize = 17.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
        // The typing fallback the iPhone has. Without it, anyone the recognizer
        // cannot understand is simply stuck.
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val typeDescription = stringResource(R.string.g_aim_type_description)
            OutlinedTextField(
                value = typed,
                onValueChange = onTyped,
                singleLine = true,
                label = { Text(stringResource(R.string.g_aim_type_label)) },
                modifier = Modifier
                    .weight(1f)
                    .semantics { contentDescription = typeDescription },
            )
            Button(onClick = onSubmit, enabled = typed.isNotBlank()) { Text(stringResource(R.string.g_aim_find)) }
        }
        if (recent.isNotEmpty()) {
            val names by androidx.compose.runtime.produceState(emptyMap<String, String>(), recent) {
                value = withContext(kotlinx.coroutines.Dispatchers.IO) { recent.associateWith { AimNames.bare(it) } }
            }
            Text(
                stringResource(R.string.g_aim_found_before),
                color = Color.White,
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.semantics { heading() },
            )
            @OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
            androidx.compose.foundation.layout.FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                for (word in recent) {
                    // The finder's English word, shown in the app's language once translated.
                    val name = names[word] ?: word
                    SmallButton(name.replaceFirstChar { it.uppercase() }, stringResource(R.string.g_aim_look_for, name)) { onPickRecent(word) }
                }
                SmallButton(stringResource(R.string.g_aim_clear_list), stringResource(R.string.g_aim_clear_recent), onClearRecent)
            }
        }
        Spacer(Modifier.weight(1f))
    }
}

@Composable
private fun Aiming(
    previewView: PreviewView,
    subjectName: String,
    isFace: Boolean,
    isFront: Boolean,
    torchOn: Boolean,
    countdownWord: String?,
    statusText: String,
    onShootNow: () -> Unit,
    onBack: () -> Unit,
    onToggleCamera: () -> Unit,
    onToggleTorch: () -> Unit,
) {
    val cameraDescription = stringResource(R.string.g_aim_camera_description, subjectName)
    Box(Modifier.fillMaxSize()) {
        AndroidView(
            factory = { previewView },
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(Unit) { detectTapGestures(onDoubleTap = { onShootNow() }) }
                .semantics {
                    contentDescription = cameraDescription
                },
        )

        Column(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().liveSafePadding(top = true).padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SmallButton(stringResource(R.string.g_aim_back), stringResource(R.string.g_aim_back_to_choices), onBack)
                Spacer(Modifier.weight(1f))
                if (isFace) {
                    SmallButton(
                        stringResource(if (isFront) R.string.g_aim_back_cam else R.string.g_aim_front_cam),
                        stringResource(if (isFront) R.string.g_aim_switch_back else R.string.g_aim_switch_front),
                        onToggleCamera,
                    )
                }
                if (!isFront) {
                    SmallButton(
                        stringResource(if (torchOn) R.string.g_aim_torch_on_pill else R.string.g_aim_torch_off_pill),
                        stringResource(if (torchOn) R.string.g_aim_torch_on_label else R.string.g_aim_torch_off_label),
                        onToggleTorch,
                    )
                }
            }

            Spacer(Modifier.weight(1f))
            if (countdownWord != null) {
                Text(
                    countdownWord,
                    color = Color.White,
                    fontSize = 120.sp,
                    fontWeight = FontWeight.Bold,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Spacer(Modifier.weight(1f))

            // Visible for a sighted helper. TalkBack hears the spoken line
            // instead, so this panel is not read out twice — same choice the
            // iPhone makes with accessibilityHidden.
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
                    .padding(bottom = 24.dp)
                    .liveSafePadding(horizontal = true, bottom = true, navOnly = true)
                    .clip(RoundedCornerShape(14.dp))
                    .background(Color.Black.copy(alpha = 0.55f))
                    .padding(12.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    statusText,
                    color = Color.White,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center,
                )
                Text(
                    stringResource(R.string.g_aim_double_tap_now),
                    color = Color.White.copy(alpha = 0.8f),
                    fontSize = 13.sp,
                )
            }
        }
    }
}

@Composable
private fun Taken(
    photo: android.graphics.Bitmap?,
    statusText: String,
    subjectName: String,
    onTakeAnother: () -> Unit,
    onBack: () -> Unit,
) {
    Column(
        // Scrolls: a long description was cut off under the photo (Matt, 2026-11-03).
        Modifier.fillMaxSize().liveSafePadding(horizontal = true, bottom = true, navOnly = true)
            .verticalScroll(androidx.compose.foundation.rememberScrollState())
            .padding(horizontal = 16.dp).padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        TopBar(stringResource(R.string.g_aim_taken_title), stringResource(R.string.g_aim_back_to_choices), onBack)
        if (photo != null) {
            androidx.compose.foundation.Image(
                bitmap = photo.asImageBitmap(),
                contentDescription = stringResource(R.string.g_aim_photo_description),
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 360.dp)
                    .clip(RoundedCornerShape(12.dp)),
            )
        } else {
            CircularProgressIndicator(color = Color.White)
        }
        Text(
            statusText,
            color = Color.White,
            fontSize = 17.sp,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().semantics { liveRegion = LiveRegionMode.Polite },
        )
        AimBigButton(
            "📸", stringResource(R.string.g_aim_take_another), IosGreen,
            stringResource(R.string.g_aim_take_another_hint, subjectName), onTakeAnother,
        )
        AimBigButton(
            "↩️", stringResource(R.string.g_aim_back), IosGray,
            stringResource(R.string.g_aim_back_to_three), onBack,
        )
    }
}

/**
 * One spoken answer. The timings come from AimListening, so the phone waits
 * exactly as long as the iPhone does before giving up.
 */
class AimListener(private val context: Context) {
    private var recognizer: SpeechRecognizer? = null

    val available: Boolean get() = SpeechRecognizer.isRecognitionAvailable(context)

    /** The transcript, or null when nothing usable was heard. */
    suspend fun listen(language: String = "en"): String? {
        if (!available) return null
        val done = CompletableDeferred<String?>()
        val r = SpeechRecognizer.createSpeechRecognizer(context).also { recognizer = it }
        r.setRecognitionListener(object : RecognitionListener {
            override fun onResults(results: Bundle?) {
                val text = results
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()
                if (!done.isCompleted) done.complete(text)
            }

            override fun onError(error: Int) { if (!done.isCompleted) done.complete(null) }
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        val intent = android.content.Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            // Your language: listen for it (the phone's own language otherwise, as before).
            if (language != "en") putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
            putExtra(
                RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                (AimListening.silence * 1000).toLong(),
            )
        }
        r.startListening(intent)
        val heard = withTimeoutOrNull((AimListening.maxTotal * 1000).toLong()) { done.await() }
        r.stopListening()
        r.destroy()
        recognizer = null
        return heard
    }

    fun close() {
        recognizer?.destroy()
        recognizer = null
    }
}

/** Help Me Aim input in Your language, put into English for the finder. Pure, unit tested. */
object AimInput {
    /** [translate] (text, fromLanguage) -> English or null. Falls back to what was said. */
    fun toEnglish(word: String, lang: String, translate: (String, String) -> String?): String {
        val w = word.trim()
        if (lang == "en" || w.isEmpty()) return w
        val out = translate(w, lang)?.trim()?.trimEnd('.', '!', '?')
        return if (out.isNullOrBlank()) w else out
    }
}
