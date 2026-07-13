package com.mattmacosko.realtimeaicam.camera

import android.annotation.SuppressLint
import android.content.Context
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
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.mattmacosko.realtimeaicam.translation.SpanishTranslationEngine
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Live OCR frame flow (iOS LiveOCRViewModel): CameraX -> ML Kit text
 * recognition -> StateFlows. Spanish mode adds the offline dictionary+rules
 * translation engine (tier 6 agent port). Frame processing pauses while
 * translating and once a translation is displayed (until reset), like iOS.
 */
class OcrPipeline(context: Context, val isSpanish: Boolean) {

    companion object {
        private const val TAG = "OcrPipeline"
        private const val MIN_INTERVAL_MS = 700L

        // Shared engine: loaded once per process, ~27MB decompressed.
        @Volatile private var sharedEngine: SpanishTranslationEngine? = null
        private val engineLoading = AtomicBoolean(false)
    }

    private val appContext = context.applicationContext

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

    /** Green speak-button state (iOS isSpeaking): true only while TTS plays. */
    val isSpeaking: StateFlow<Boolean> = speaker.speakingNow

    private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private val workExecutor = Executors.newSingleThreadExecutor()
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var busy = false
    private var lastProcessed = 0L

    init {
        if (isSpanish) ensureEngineLoaded()
    }

    private fun ensureEngineLoaded() {
        if (sharedEngine?.isLoaded == true) {
            engineReady.value = true
            return
        }
        if (!engineLoading.compareAndSet(false, true)) return
        workExecutor.execute {
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
                    Log.i(TAG, "Translation engine loaded: ${engine.entryCount} entries")
                    // One-time smoke test against the iOS-traced expected pairs
                    listOf(
                        "El menú del día",
                        "El gato negro come arroz",
                        "Se vende pan",
                        "¿Dónde está el baño?",
                        "Por la mañana quiero un café",
                    ).forEach { s ->
                        Log.i(TAG, "smoke: '$s' -> '${engine.translate(s)}'")
                    }
                } else {
                    Log.e(TAG, "Translation engine load failed")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Translation engine load error", e)
            } finally {
                engineLoading.set(false)
            }
        }
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
    }

    fun stop() {
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
        recognizer.close()
        analysisExecutor.shutdown()
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
        frozen.value = false
    }

    /** Spanish mode: translate the current text with the offline engine. */
    fun translate() {
        val text = recognizedText.value
        if (text.isBlank() || isTranslating.value) return
        val engine = sharedEngine
        if (engine?.isLoaded != true) {
            ensureEngineLoaded()
            return
        }
        isTranslating.value = true
        frozen.value = true // pause OCR during + after translation (iOS)
        workExecutor.execute {
            val result = try {
                engine.translate(text)
            } catch (e: Exception) {
                Log.e(TAG, "translate failed", e)
                text
            }
            translatedText.value = result
            isTranslating.value = false
            showTranslationPopup.value = true
        }
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
        if (toSpeak.isNotBlank()) speaker.speak(toSpeak)
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
