package com.mattmacosko.realtimeaicam.camera

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.SystemClock
import android.util.Log
import androidx.camera.core.AspectRatio
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.mattmacosko.realtimeaicam.translation.ReaderLanguage
import com.mattmacosko.realtimeaicam.translation.ReaderLanguages
import com.mattmacosko.realtimeaicam.translation.SpanishIdiomPrepass
import com.mattmacosko.realtimeaicam.translation.SpanishTranslationEngine
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Live OCR frame flow (iOS LiveOCRViewModel): CameraX -> ML Kit text
 * recognition -> StateFlows. Translator mode sends every language, Spanish
 * included, through Google's on-device translator (Spanish with whole idioms
 * matched first, SpanishIdiomPrepass). The built-in dictionary+rules engine is
 * Spanish's fallback and loads only when that fallback is actually used. Frame
 * processing pauses while translating and once a translation is displayed
 * (until reset), like iOS.
 */
class OcrPipeline(context: Context, val isSpanish: Boolean) {

    companion object {
        private const val TAG = "OcrPipeline"
        private const val MIN_INTERVAL_MS = 700L
        private const val AUTO_TICK_MS = 250L
        /** After speech ends, a beat before Auto reads the next page. */
        private const val AFTER_SPEECH_GAP_MS = 500L
        /** A line handed to the voice may take this long to start; don't flush it meanwhile. */
        private const val VOICE_START_GRACE_MS = 2_000L

        // Shared dictionary engine (~65 MB in memory): loaded only when Spanish falls back to it.
        @Volatile private var sharedEngine: SpanishTranslationEngine? = null
        private val engineLoading = AtomicBoolean(false)

        /**
         * Spanish's Google pack failed to download this launch (most often offline): go straight
         * to the dictionary instead of trying again on every scan, until the next launch (iOS
         * spanishDownloadDeclined).
         */
        @Volatile private var spanishDownloadFailed = false

        /** Drop the dictionary so another AI can have the memory; it reloads on the next Spanish scan. */
        fun releaseSharedEngine() {
            if (engineLoading.get()) return
            sharedEngine = null
        }
    }

    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("rtcam", Context.MODE_PRIVATE)

    /** Translator mode: which language the page is in. */
    val sourceLanguage = MutableStateFlow(ReaderLanguages.byCode(prefs.getString("translateFrom", "es")))

    /** Shown in the text card instead of the page while a language pack is needed or downloading. */
    val notice = MutableStateFlow<String?>(null)

    // Google's translator for the current language. Touched only on workExecutor.
    private var mlTranslator: Translator? = null
    private var mlTranslatorCode: String? = null

    val recognizedText = MutableStateFlow("")
    val translatedText = MutableStateFlow<String?>(null)
    val isTranslating = MutableStateFlow(false)
    val showTranslationPopup = MutableStateFlow(false)
    val engineReady = MutableStateFlow(sharedEngine?.isLoaded == true)

    private val _torchOn = MutableStateFlow(false)
    val torchOn: StateFlow<Boolean> = _torchOn.asStateFlow()
    private val _zoomRatio = MutableStateFlow(1f)
    val zoomRatio: StateFlow<Float> = _zoomRatio.asStateFlow()

    /** Frozen after translation until reset (iOS pauses OCR then). */
    private val frozen = MutableStateFlow(false)

    val speaker = SpeechAnnouncer(appContext)

    /** Tap to read / Auto read / Mute (the small button next to Speak), remembered. */
    val readingMode = MutableStateFlow(ReadingMode.fromKey(prefs.getString(ReadingMode.PREF_KEY, null)))
    private val autoGate = AutoReadGate()
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    /** Auto read stays quiet until then: a line was just handed to the voice or TalkBack. */
    private var quietUntil = 0L
    private var autoTicking = false
    private val autoTick = object : Runnable {
        override fun run() {
            if (!autoTicking) return
            autoReadStep()
            mainHandler.postDelayed(this, AUTO_TICK_MS)
        }
    }

    /** Green speak-button state (iOS isSpeaking): true only while TTS plays. */
    val isSpeaking: StateFlow<Boolean> = speaker.speakingNow

    private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private val workExecutor = Executors.newSingleThreadExecutor()
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var busy = false
    private var lastProcessed = 0L

    /**
     * The dictionary engine, loaded on first use on the calling (work) thread. Nothing loads it
     * when Translator opens any more: Spanish goes to Google first (2026-10-23).
     */
    private fun dictionaryEngine(): SpanishTranslationEngine? {
        sharedEngine?.let { if (it.isLoaded) return it }
        if (!engineLoading.compareAndSet(false, true)) return null
        run {
            try {
                val engine = SpanishTranslationEngine()
                // AAPT auto-decompresses .gz assets and drops the extension, so
                // the APK ships assets/es_final_with_rules.json (plain). Support
                // both layouts.
                val ok = try {
                    engine.load(appContext.assets.open("es_final_with_rules.json"), gzipped = false)
                } catch (e: java.io.FileNotFoundException) {
                    engine.load(appContext.assets.open("es_final_with_rules.json.gz"))
                }
                if (ok) {
                    sharedEngine = engine
                    engineReady.value = true
                    Log.i(TAG, "Dictionary engine loaded (fallback): ${engine.entryCount} entries")
                } else {
                    Log.e(TAG, "Translation engine load failed")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Translation engine load error", e)
            } finally {
                engineLoading.set(false)
            }
        }
        return sharedEngine?.takeIf { it.isLoaded }
    }

    fun start(lifecycleOwner: LifecycleOwner, previewView: PreviewView) {
        val providerFuture = ProcessCameraProvider.getInstance(appContext)
        providerFuture.addListener({
            val provider = providerFuture.get()
            cameraProvider = provider

            val resolutionSelector = ResolutionSelector.Builder()
                .setAspectRatioStrategy(
                    AspectRatioStrategy(AspectRatio.RATIO_4_3, AspectRatioStrategy.FALLBACK_RULE_AUTO)
                )
                .build()

            previewView.scaleType = PreviewView.ScaleType.FILL_CENTER

            val preview = Preview.Builder()
                .setResolutionSelector(resolutionSelector)
                .build()
                .also { it.setSurfaceProvider(previewView.surfaceProvider) }

            val analysis = ImageAnalysis.Builder()
                .setResolutionSelector(resolutionSelector)
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { it.setAnalyzer(analysisExecutor, ::analyze) }

            try {
                provider.unbindAll()
                camera = provider.bindToLifecycle(
                    lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis
                )
            } catch (e: Exception) {
                Log.e(TAG, "Camera bind failed", e)
            }
        }, ContextCompat.getMainExecutor(appContext))
        setAutoTicking(readingMode.value == ReadingMode.AUTO)
    }

    fun stop() {
        setAutoTicking(false)
        setTorch(false)
        speaker.stop()
        cameraProvider?.unbindAll()
        cameraProvider = null
        camera = null
        _zoomRatio.value = 1f
        reset()
    }

    fun shutdown() {
        stop()
        speaker.shutdown()
        // After any frame already on the analysis thread, not underneath it.
        analysisExecutor.execute { recognizer.close() }
        analysisExecutor.shutdown()
        workExecutor.execute { mlTranslator?.close(); mlTranslator = null }
        workExecutor.shutdown()
    }

    fun setTorch(on: Boolean) {
        camera?.cameraControl?.enableTorch(on)
        _torchOn.value = on
    }

    fun onPinch(scaleFactor: Float) {
        val cam = camera ?: return
        val zs = cam.cameraInfo.zoomState.value
        val clamped = (_zoomRatio.value * scaleFactor)
            .coerceIn(zs?.minZoomRatio ?: 1f, zs?.maxZoomRatio ?: 1f)
        cam.cameraControl.setZoomRatio(clamped)
        _zoomRatio.value = clamped
    }

    /** Reset button: clears text + translation, stops speech, resumes OCR. */
    fun reset() {
        speaker.stop()
        recognizedText.value = ""
        translatedText.value = null
        isTranslating.value = false
        showTranslationPopup.value = false
        notice.value = null
        frozen.value = false
        autoGate.reset()
    }

    // ---- Reading mode: Tap to read / Auto read / Mute ----

    /** The small button next to Speak: step to the next mode, remember it, and say its name. */
    fun cycleReadingMode() {
        val mode = readingMode.value.next
        prefs.edit().putString(ReadingMode.PREF_KEY, mode.key).apply()
        readingMode.value = mode
        Log.i(TAG, "reading mode -> ${mode.key}")
        // Said even for Mute: the person has to hear what they picked. Flushes anything playing.
        speaker.speak(mode.label)
        holdAutoFor(mode.label)
        setAutoTicking(mode == ReadingMode.AUTO)
    }

    private fun setAutoTicking(on: Boolean) {
        if (on == autoTicking) return
        autoTicking = on
        mainHandler.removeCallbacks(autoTick)
        if (on) mainHandler.postDelayed(autoTick, AUTO_TICK_MS)
    }

    /** Keep Auto read from talking over a line that was just handed to the voice / TalkBack. */
    private fun holdAutoFor(line: String) {
        val now = SystemClock.elapsedRealtime()
        val hold = if (speaksAloud()) VOICE_START_GRACE_MS else AnnouncementRules.estimatedMs(line)
        quietUntil = maxOf(quietUntil, now + hold)
    }

    private fun speaksAloud(): Boolean = prefs.getBoolean("speakAnswersAloud", true)

    /**
     * One Auto read step (main thread, every [AUTO_TICK_MS]). The translation is preferred
     * when there is one; otherwise the text the camera is reading. A language-pack notice is
     * already said by [showNotice], so nothing else is read while it shows.
     */
    private fun autoReadStep() {
        if (readingMode.value != ReadingMode.AUTO) return
        val now = SystemClock.elapsedRealtime()
        if (speaker.speakingNow.value) quietUntil = maxOf(quietUntil, now + AFTER_SPEECH_GAP_MS)
        if (notice.value != null || isTranslating.value) return
        val candidate = translatedText.value ?: recognizedText.value
        if (candidate.isBlank()) return
        autoGate.observe(candidate, now)
        val line = autoGate.due(now, busy = speaker.speakingNow.value || now < quietUntil) ?: return
        autoGate.markSpoken(line, now)
        Log.i(TAG, "auto read: ${line.length} chars")
        speaker.speak(line)
        holdAutoFor(line)
    }

    /** "Translate from" control: remember the choice and start the page over. */
    fun setSourceLanguage(lang: ReaderLanguage) {
        if (lang == sourceLanguage.value) return
        prefs.edit().putString("translateFrom", lang.code).apply()
        sourceLanguage.value = lang
        reset()
    }

    /** Translate the current text into English. */
    fun translate() {
        val text = recognizedText.value
        if (text.isBlank() || isTranslating.value) return
        notice.value = null
        isTranslating.value = true
        frozen.value = true // pause OCR during + after translation (iOS)
        val lang = sourceLanguage.value
        val spanish = lang.code == ReaderLanguages.spanish.code
        workExecutor.execute {
            val result = if (spanish && spanishDownloadFailed) {
                translateWithDictionary(text)
            } else {
                translateWithGoogle(text, lang, spanish)
            }
            isTranslating.value = false
            if (result != null) {
                notice.value = null
                translatedText.value = result
                com.mattmacosko.realtimeaicam.RatePrompt.noteResult(appContext)
                showTranslationPopup.value = true
            } else {
                frozen.value = false // nothing to show, keep reading the page
            }
        }
    }

    /**
     * Google's on-device translator, every language. The first time a language is used its pack
     * downloads (about 30 MB); after that it works with no connection at all. Spanish never comes
     * back empty: with no pack and no way to get one, or on any error, the dictionary answers.
     * Runs on workExecutor.
     */
    private fun translateWithGoogle(text: String, lang: ReaderLanguage, spanish: Boolean): String? {
        var downloading = false
        return try {
            val translator = translatorFor(lang.code)
            val model = TranslateRemoteModel.Builder(lang.code).build()
            val have = Tasks.await(RemoteModelManager.getInstance().isModelDownloaded(model))
            if (!have) {
                if (spanish) {
                    // Say it even offline (iOS announces before trying): the person learns the
                    // better translation is one download away, and still gets English now.
                    showNotice(ReaderLanguages.downloadLine(lang.name))
                    if (!isOnline()) {
                        spanishDownloadFailed = true
                        Log.i(TAG, "Spanish pack not on the phone and offline: dictionary")
                        return translateWithDictionary(text)
                    }
                } else if (!isOnline()) {
                    showNotice("${lang.name} needs a one-time download from Google. Connect to the internet once, then it works offline.")
                    return null
                } else {
                    showNotice(ReaderLanguages.downloadLine(lang.name))
                }
                downloading = true
                Tasks.await(
                    translator.downloadModelIfNeeded(DownloadConditions.Builder().build()),
                    5, TimeUnit.MINUTES,
                )
                downloading = false
            }
            val english = if (spanish) {
                // Whole idioms first ("No hay mal que por bien no venga" -> "Every cloud has a
                // silver lining"), the rest through Google, sign lines kept apart.
                // The reader wraps long lines ("No hay mal que por\nbien no venga."), so the
                // idiom check sees the sign-line units, which already re-join wrapped lines.
                loadIdioms()
                val units = SpanishTranslationEngine.translationUnits(text).joinToString("\n")
                SpanishIdiomPrepass.translate(units) { translateLines(translator, it) }
            } else {
                translateLines(translator, text)
            }
            english.ifBlank { null } ?: if (spanish) translateWithDictionary(text) else text
        } catch (e: Exception) {
            Log.e(TAG, "translate (${lang.code}) failed", e)
            if (spanish) {
                if (downloading) spanishDownloadFailed = true
                translateWithDictionary(text)
            } else {
                showNotice("${lang.name} couldn't be translated just now. Please try again.")
                null
            }
        }
    }

    /** The built-in Spanish engine (fallback). Loads it on first use. Runs on workExecutor. */
    private fun translateWithDictionary(text: String): String {
        val engine = dictionaryEngine()
            ?: return "Translation data couldn't load. Please close and reopen the app."
        return try {
            // Translate the lines, not one run-on: a sign's lines are separate
            // phrases, and the engine reordered words across them (iOS 2026-09-16).
            SpanishTranslationEngine.translationUnits(text)
                .map { engine.translate(it) }
                .filter { it.isNotEmpty() }
                .joinToString("\n")
                .ifEmpty { text }
        } catch (e: Exception) {
            Log.e(TAG, "dictionary translate failed", e)
            text
        }
    }

    private fun loadIdioms() {
        if (SpanishIdiomPrepass.isLoaded) return
        try {
            SpanishIdiomPrepass.load { appContext.assets.open("es_idioms.json") }
        } catch (e: Exception) {
            Log.e(TAG, "idiom list failed to load", e) // translation still works, just word for word
        }
    }

    private fun translatorFor(code: String): Translator {
        mlTranslator?.let { if (mlTranslatorCode == code) return it }
        mlTranslator?.close()
        val t = Translation.getClient(
            TranslatorOptions.Builder()
                .setSourceLanguage(code)
                .setTargetLanguage(TranslateLanguage.ENGLISH)
                .build()
        )
        mlTranslator = t
        mlTranslatorCode = code
        return t
    }

    private fun translateLines(translator: Translator, text: String): String =
        SpanishTranslationEngine.translationUnits(text)
            .map { Tasks.await(translator.translate(it)).trim() }
            .filter { it.isNotEmpty() }
            .joinToString("\n")
            .ifEmpty { text }

    private fun showNotice(message: String) {
        Log.i(TAG, "notice: $message")
        notice.value = message
        if (readingMode.value == ReadingMode.MUTE) return // Mute: on screen only
        ContextCompat.getMainExecutor(appContext).execute {
            speaker.speak(message)
            holdAutoFor(message)
        }
    }

    private fun isOnline(): Boolean {
        val cm = appContext.getSystemService(ConnectivityManager::class.java) ?: return false
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    /**
     * iOS speakButton: tapping while speaking STOPS speech (clears green
     * instantly); otherwise speak only if there is text — no utterance is
     * ever started for blank text, so the button never turns green silently.
     */
    fun speakCurrent() {
        if (speaker.speakingNow.value) {
            speaker.stop()
            return
        }
        val toSpeak = translatedText.value ?: recognizedText.value
        if (toSpeak.isNotBlank()) {
            com.mattmacosko.realtimeaicam.RatePrompt.noteResult(appContext)
            speaker.speak(toSpeak)
            // Read by hand: Auto read won't say the same page again right after.
            autoGate.markSpoken(toSpeak, SystemClock.elapsedRealtime())
            holdAutoFor(toSpeak)
        }
    }

    // ---- Frame path ----

    @SuppressLint("UnsafeOptInUsageError")
    private fun analyze(image: ImageProxy) {
        val media = image.image
        val now = SystemClock.elapsedRealtime()
        if (media == null || busy || frozen.value || isTranslating.value ||
            now - lastProcessed < MIN_INTERVAL_MS
        ) {
            image.close()
            return
        }
        busy = true
        lastProcessed = now
        val input = InputImage.fromMediaImage(media, image.imageInfo.rotationDegrees)
        recognizer.process(input)
            .addOnSuccessListener { result ->
                if (!frozen.value) {
                    val text = result.text.trim()
                    if (text.isNotEmpty()) recognizedText.value = text
                }
            }
            .addOnFailureListener { e -> Log.w(TAG, "OCR failed", e) }
            .addOnCompleteListener {
                busy = false
                image.close()
            }
    }
}
