package com.mattmacosko.realtimeaicam.camera

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
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
import com.mattmacosko.realtimeaicam.detection.DetectorConfig
import com.mattmacosko.realtimeaicam.detection.LetterboxInfo
import com.mattmacosko.realtimeaicam.detection.ObjectTracker
import com.mattmacosko.realtimeaicam.detection.YoloDetector
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.min

/**
 * Android counterpart of the iOS CameraViewModel frame flow:
 * CameraX ImageAnalysis (KEEP_ONLY_LATEST) -> upright RGB bitmap ->
 * 640x640 letterbox -> YoloDetector -> ObjectTracker -> StateFlow for Compose.
 * All inference runs on a single background executor, never the main thread.
 */
class DetectionPipeline(
    context: Context,
    private val config: DetectorConfig = DetectorConfig(),
) {

    companion object {
        private const val TAG = "DetectionPipeline"
        private const val FPS_WINDOW = 30
    }

    private val appContext = context.applicationContext

    private val _uiState = MutableStateFlow(DetectionUiState())
    val uiState: StateFlow<DetectionUiState> = _uiState.asStateFlow()

    private val tracker = ObjectTracker()
    private var detector: YoloDetector? = null

    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null

    /** User-facing camera controls (iOS parity: torch, pinch zoom, confidence). */
    private val _torchOn = MutableStateFlow(false)
    val torchOn: StateFlow<Boolean> = _torchOn.asStateFlow()
    private val _zoomRatio = MutableStateFlow(1f)
    val zoomRatio: StateFlow<Float> = _zoomRatio.asStateFlow()

    /** Confidence slider value 0.0001..1.0 (iOS default 0.75). */
    val confidenceThreshold = MutableStateFlow(0.75f)

    /** "all" | "indoor" | "outdoor" — iOS filterMode with the same class sets. */
    val filterMode = MutableStateFlow("all")
    private val indoorAllowed: Set<String> by lazy { loadClassSet("indoor_classes.txt") + loadClassSet("both_classes.txt") }
    private val outdoorAllowed: Set<String> by lazy { loadClassSet("outdoor_classes.txt") + loadClassSet("both_classes.txt") }

    private fun loadClassSet(asset: String): Set<String> = try {
        appContext.assets.open(asset).bufferedReader().readLines()
            .map { it.trim() }.filter { it.isNotEmpty() }.toSet()
    } catch (e: Exception) {
        emptySet()
    }

    private fun applyFilter(detections: List<com.mattmacosko.realtimeaicam.detection.Detection>) =
        when (filterMode.value) {
            "indoor" -> detections.filter { it.className in indoorAllowed }
            "outdoor" -> detections.filter { it.className in outdoorAllowed }
            else -> detections
        }

    /** Camera facing + lens state (iOS parity: flip + ultra-wide toggle). */
    private val _isFrontCamera = MutableStateFlow(false)
    val isFrontCamera: StateFlow<Boolean> = _isFrontCamera.asStateFlow()
    private val _hasUltraWide = MutableStateFlow(false)
    val hasUltraWide: StateFlow<Boolean> = _hasUltraWide.asStateFlow()
    private val _isUltraWide = MutableStateFlow(false)
    val isUltraWide: StateFlow<Boolean> = _isUltraWide.asStateFlow()

    /** 🗣️ speech announcements (iOS handleToggleSpeech). */
    val announcer = SpeechAnnouncer(appContext)

    private var boundLifecycleOwner: LifecycleOwner? = null
    private var boundPreviewView: PreviewView? = null

    /** iOS handleFlipCamera: stop speech, toggle front/rear, rebind, reset zoom. */
    fun flipCamera() {
        val owner = boundLifecycleOwner ?: return
        val view = boundPreviewView ?: return
        announcer.stop() // iOS stops all speech immediately on flip
        _isFrontCamera.value = !_isFrontCamera.value
        _isUltraWide.value = false
        tracker.reset()
        _uiState.update { it.copy(detections = emptyList()) }
        start(owner, view)
    }

    /**
     * iOS handleToggleCameraZoom (ultra-wide): implemented via sub-1.0 zoom on
     * devices whose logical camera exposes it; the button is hidden otherwise.
     */
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

    fun setTorch(on: Boolean) {
        camera?.cameraControl?.enableTorch(on)
        _torchOn.value = on
    }

    fun setZoom(ratio: Float) {
        val cam = camera ?: return
        val zs = cam.cameraInfo.zoomState.value
        val clamped = ratio.coerceIn(zs?.minZoomRatio ?: 1f, zs?.maxZoomRatio ?: 1f)
        cam.cameraControl.setZoomRatio(clamped)
        _zoomRatio.value = clamped
    }

    fun onPinch(scaleFactor: Float) {
        setZoom(_zoomRatio.value * scaleFactor)
    }

    // Reused per-frame scratch (single-threaded analyzer, so this is safe)
    private var letterboxBitmap: Bitmap? = null
    private var letterboxCanvas: Canvas? = null
    private val letterboxMatrix = Matrix()
    private val letterboxPaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val frameTimestamps = ArrayDeque<Long>()

    init {
        // Load the model off the main thread; surface a friendly error if missing.
        analysisExecutor.execute {
            try {
                val d = YoloDetector.create(appContext, config)
                detector = d
                _uiState.update {
                    it.copy(
                        modelError = null,
                        outputShape = "${d.outputShapeString} ${d.backendDescription}",
                    )
                }
            } catch (e: Exception) {
                Log.e(TAG, "Model load failed", e)
                _uiState.update { it.copy(modelError = e.message ?: "Model load failed") }
            }
        }
    }

    /** Binds preview + analysis to [lifecycleOwner], rendering into [previewView]. */
    fun start(lifecycleOwner: LifecycleOwner, previewView: PreviewView) {
        _zoomRatio.value = 1f
        _torchOn.value = false
        boundLifecycleOwner = lifecycleOwner
        boundPreviewView = previewView
        val providerFuture = ProcessCameraProvider.getInstance(appContext)
        providerFuture.addListener({
            val provider = providerFuture.get()
            cameraProvider = provider

            // Same 4:3 aspect for preview and analysis so FILL_CENTER crops match.
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
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                .build()
                .also { it.setAnalyzer(analysisExecutor, ::analyze) }

            try {
                provider.unbindAll()
                val selector =
                    if (_isFrontCamera.value) CameraSelector.DEFAULT_FRONT_CAMERA
                    else CameraSelector.DEFAULT_BACK_CAMERA
                camera = provider.bindToLifecycle(
                    lifecycleOwner,
                    selector,
                    preview,
                    analysis,
                )
                _hasUltraWide.value =
                    !_isFrontCamera.value &&
                        (camera?.cameraInfo?.zoomState?.value?.minZoomRatio ?: 1f) < 1f
                // Restore control state after (re)bind
                if (_torchOn.value) camera?.cameraControl?.enableTorch(true)
                if (_zoomRatio.value != 1f) setZoom(_zoomRatio.value)
            } catch (e: Exception) {
                Log.e(TAG, "Camera bind failed", e)
            }
        }, ContextCompat.getMainExecutor(appContext))
    }

    fun stop() {
        setTorch(false)
        announcer.stop()
        cameraProvider?.unbindAll()
        cameraProvider = null
        camera = null
        boundLifecycleOwner = null
        boundPreviewView = null
        _zoomRatio.value = 1f
        _isFrontCamera.value = false
        _isUltraWide.value = false
        tracker.reset()
        _uiState.update { it.copy(detections = emptyList()) }
    }

    fun shutdown() {
        stop()
        announcer.shutdown()
        analysisExecutor.execute {
            detector?.close()
            detector = null
        }
        analysisExecutor.shutdown()
    }

    // ---- Frame path (runs on analysisExecutor) ----

    private fun analyze(image: ImageProxy) {
        image.use {
            val detector = detector ?: return
            val rotation = image.imageInfo.rotationDegrees

            // RGBA_8888 output format -> toBitmap() is a cheap buffer copy.
            // Rotation is folded into the letterbox matrix draw, so no
            // intermediate rotated bitmap is allocated per frame.
            val bitmap = image.toBitmap()

            val letterbox = letterboxInto(
                bitmap,
                rotation,
                mirror = _isFrontCamera.value, // PreviewView mirrors front camera
                detector.inputWidth,
                detector.inputHeight,
            )

            val t0 = SystemClock.elapsedRealtime()
            val raw = applyFilter(
                detector.detect(letterboxBitmap!!, letterbox, confidenceThreshold.value)
            )
            val inferenceMs = SystemClock.elapsedRealtime() - t0

            val smoothed = tracker.update(raw)
            announcer.announce(smoothed)

            val now = SystemClock.elapsedRealtime()
            frameTimestamps.addLast(now)
            while (frameTimestamps.size > FPS_WINDOW) frameTimestamps.removeFirst()
            val fps = if (frameTimestamps.size >= 2) {
                val spanSec = (frameTimestamps.last() - frameTimestamps.first()) / 1000f
                if (spanSec > 0f) (frameTimestamps.size - 1) / spanSec else 0f
            } else 0f

            _uiState.update {
                it.copy(
                    detections = smoothed,
                    fps = fps,
                    inferenceMs = inferenceMs,
                    frameWidth = letterbox.srcWidth,
                    frameHeight = letterbox.srcHeight,
                )
            }
        }
    }

    /**
     * Rotates [src] upright by [rotationDegrees] and scales it into a
     * black-padded square model input (aspect preserved) in a single matrix
     * draw, reusing one bitmap. Returns the letterbox transform for coordinate
     * mapping; srcWidth/srcHeight are the UPRIGHT (rotated) frame dimensions.
     */
    private fun letterboxInto(
        src: Bitmap,
        rotationDegrees: Int,
        mirror: Boolean,
        dstW: Int,
        dstH: Int,
    ): LetterboxInfo {
        var target = letterboxBitmap
        if (target == null || target.width != dstW || target.height != dstH) {
            target = Bitmap.createBitmap(dstW, dstH, Bitmap.Config.ARGB_8888)
            letterboxBitmap = target
            letterboxCanvas = Canvas(target)
        }
        val canvas = letterboxCanvas!!
        canvas.drawColor(Color.BLACK)

        val swap = rotationDegrees == 90 || rotationDegrees == 270
        val uprightW = if (swap) src.height else src.width
        val uprightH = if (swap) src.width else src.height

        val scale = min(dstW.toFloat() / uprightW, dstH.toFloat() / uprightH)
        val padX = (dstW - uprightW * scale) / 2f
        val padY = (dstH - uprightH * scale) / 2f

        // Rotate around the source center, scale, then move the center to the
        // middle of the (square) destination — padding falls out symmetric.
        letterboxMatrix.reset()
        letterboxMatrix.postTranslate(-src.width / 2f, -src.height / 2f)
        letterboxMatrix.postRotate(rotationDegrees.toFloat())
        // Mirror the upright frame horizontally so detections line up with the
        // (mirrored) front-camera preview.
        if (mirror) letterboxMatrix.postScale(-1f, 1f)
        letterboxMatrix.postScale(scale, scale)
        letterboxMatrix.postTranslate(dstW / 2f, dstH / 2f)
        canvas.drawBitmap(src, letterboxMatrix, letterboxPaint)

        return LetterboxInfo(
            scale = scale,
            padX = padX,
            padY = padY,
            srcWidth = uprightW,
            srcHeight = uprightH,
        )
    }
}
