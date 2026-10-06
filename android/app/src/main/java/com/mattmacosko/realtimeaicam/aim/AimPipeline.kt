package com.mattmacosko.realtimeaicam.aim

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.os.Build
import android.os.SystemClock
import android.net.Uri
import android.provider.MediaStore
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.mattmacosko.realtimeaicam.camera.SpeechAnnouncer
import com.mattmacosko.realtimeaicam.detection.Detection
import com.mattmacosko.realtimeaicam.detection.LetterboxInfo
import com.mattmacosko.realtimeaicam.detection.YoloDetector
import com.mattmacosko.realtimeaicam.narrator.NarratorEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Help Me Aim on Android: the camera, the detector and the voice wired to the
 * coach.
 *
 * Every decision about what to say and when to shoot lives in HelpMeAim.kt, the
 * port of the iPhone's HelpMeAim.swift. This class only measures boxes and
 * carries out what the coach decides, so the two phones behave the same.
 */
class AimPipeline(
    context: Context,
    private val speaker: SpeechAnnouncer,
) {
    companion object {
        private const val TAG = "AimPipeline"

        /**
         * Frames taken when the countdown ends; the best framed one is kept and
         * the rest are thrown away (AimBurst.pick). Same as the iPhone.
         */
        const val BURST = 5

        /** Analysed frames per second. A weak phone cannot feed the detector faster. */
        const val MIN_FRAME_GAP_MS = 120L
    }

    private val appContext = context.applicationContext
    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private var provider: ProcessCameraProvider? = null
    private var camera: androidx.camera.core.Camera? = null
    private val imageCapture = ImageCapture.Builder()
        .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
        .build()

    @Volatile private var detector: YoloDetector? = null
    private var coach: AimCoach? = null
    private var subject: AimSubject? = null
    private var lastFrameAt = 0L

    /** Recent detector frames, for "I don't see X. I can see ..." */
    private val recentSeen = ArrayDeque<List<AimElsewhere.Seen>>()

    private val _spoken = MutableStateFlow("")
    val spoken: StateFlow<String> = _spoken.asStateFlow()

    private val _shooting = MutableStateFlow(false)
    val shooting: StateFlow<Boolean> = _shooting.asStateFlow()

    private val _done = MutableStateFlow<String?>(null)

    /** Set once a picture has been taken and saved (or failed). */
    val done: StateFlow<String?> = _done.asStateFlow()

    /** The picture just taken, shown on the Picture Taken screen like iOS. */
    private val _lastPhoto = MutableStateFlow<Bitmap?>(null)
    val lastPhoto: StateFlow<Bitmap?> = _lastPhoto.asStateFlow()

    /** "3", "2", "1" while the countdown runs, else null (iOS countdownWord). */
    private val _countdownWord = MutableStateFlow<String?>(null)
    val countdownWord: StateFlow<String?> = _countdownWord.asStateFlow()

    private val _torchOn = MutableStateFlow(false)
    val torchOn: StateFlow<Boolean> = _torchOn.asStateFlow()

    private val _isFront = MutableStateFlow(false)
    val isFront: StateFlow<Boolean> = _isFront.asStateFlow()

    private var boundOwner: LifecycleOwner? = null

    /** The What's this? model, loaded the first time a shot is described. */
    private val narrator = NarratorEngine.get(appContext)

    /** Bumped on every shot and on Take Another, so a late description of an old shot stays quiet. */
    @Volatile private var shotNumber = 0
    private var boundPreview: PreviewView? = null

    /** The class names this phone's detector knows, for the spoken lookup. */
    val classNames: List<String> get() = detector?.classNames ?: emptyList()

    fun loadDetector() {
        if (detector != null) return
        detector = try {
            YoloDetector.create(appContext)
        } catch (e: Exception) {
            Log.e(TAG, "detector load failed", e)
            null
        }
    }

    fun aimAt(s: AimSubject, now: Double = nowSeconds()) {
        subject = s
        coach = AimCoach(s).also { it.reset(now) }
        recentSeen.clear()
        _done.value = null
        _shooting.value = false
    }

    fun start(owner: LifecycleOwner, previewView: PreviewView) {
        boundOwner = owner
        boundPreview = previewView
        val future = ProcessCameraProvider.getInstance(appContext)
        future.addListener({
            val p = future.get()
            provider = p
            val preview = Preview.Builder().build()
                .also { it.setSurfaceProvider(previewView.surfaceProvider) }
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                .build()
                .also { it.setAnalyzer(analysisExecutor, ::analyze) }
            try {
                p.unbindAll()
                val selector = if (_isFront.value) {
                    CameraSelector.DEFAULT_FRONT_CAMERA
                } else {
                    CameraSelector.DEFAULT_BACK_CAMERA
                }
                camera = p.bindToLifecycle(owner, selector, preview, analysis, imageCapture)
                // A rebind drops the torch, so put it back if it was on.
                if (_torchOn.value && !_isFront.value) camera?.cameraControl?.enableTorch(true)
            } catch (e: Exception) {
                Log.e(TAG, "camera bind failed", e)
            }
        }, ContextCompat.getMainExecutor(appContext))
    }

    /**
     * Flashlight. Only the back camera has one, same as the iPhone, and the app
     * says "flashlight on" / "flashlight off" in those exact words.
     */
    fun toggleTorch(): String {
        val on = !_torchOn.value && !_isFront.value
        _torchOn.value = on
        camera?.cameraControl?.enableTorch(on)
        return if (on) "flashlight on" else "flashlight off"
    }

    fun setTorch(on: Boolean) {
        val allowed = on && !_isFront.value
        _torchOn.value = allowed
        camera?.cameraControl?.enableTorch(allowed)
    }

    /**
     * Front and back, for taking a picture of your own face. The torch goes off
     * on the way to the front camera and the coach starts over, exactly as the
     * iPhone does it.
     */
    fun toggleCamera(): String {
        _isFront.value = !_isFront.value
        setTorch(false)
        coach?.reset(nowSeconds())
        val owner = boundOwner
        val preview = boundPreview
        if (owner != null && preview != null) start(owner, preview)
        return if (_isFront.value) "front camera" else "back camera"
    }

    fun stop() {
        provider?.unbindAll()
        camera = null
    }

    fun shutdown() {
        stop()
        scope.cancel()
        // Close the detector on the frame thread, after any frame still being
        // analysed. Closing it from here freed the native interpreter under a
        // running detect() and could crash on the way out, the same class of
        // bug as the iPhone's close crash (TestFlight build 33, 2026-09-20).
        analysisExecutor.execute {
            detector?.close()
            detector = null
        }
        analysisExecutor.shutdown()
        shotNumber++
        // Off the main thread: release() waits for a description still running.
        Thread({ narrator.release() }, "aim-narrator-release").start()
    }

    // MARK: - The frame loop

    private fun analyze(image: ImageProxy) {
        try {
            val now = SystemClock.elapsedRealtime()
            if (now - lastFrameAt < MIN_FRAME_GAP_MS || _shooting.value) return
            lastFrameAt = now
            val s = subject ?: return
            val c = coach ?: return
            val rotation = image.imageInfo.rotationDegrees
            val bitmap = image.toBitmap()
            val upright = rotateUpright(bitmap, rotation)

            var faceCount = 1
            val box: AimRect?
            var seen: List<AimElsewhere.Seen> = emptyList()

            if (s is AimSubject.Face) {
                val (b, n) = runBlocking { AimVision.faces(upright) }
                box = b
                faceCount = max(1, n)
            } else {
                val d = detector
                val focus = (s as? AimSubject.Obj)?.match?.classIDs?.toIntArray()
                val detections = if (d == null) emptyList() else detect(d, upright, focus)
                seen = AimVision.seen(detections)
                box = when (s) {
                    is AimSubject.Page -> AimVision.pageBox(detections)
                    is AimSubject.Obj -> AimVision.objectBox(detections, s.match)
                    else -> null
                }
            }

            if (seen.isNotEmpty()) {
                recentSeen.addLast(seen)
                while (recentSeen.size > AimElsewhere.window) recentSeen.removeFirst()
            }
            val elsewhere = if (s is AimSubject.Face || recentSeen.isEmpty()) {
                null
            } else {
                AimElsewhere.sentence(
                    s,
                    AimElsewhere.pick(recentSeen.toList(), AimElsewhere.targetNames(s)),
                )
            }

            val actions = c.observe(
                raw = box,
                faceCount = faceCount,
                now = nowSeconds(),
                voiceBusy = speaker.speakingNow.value,
                elsewhere = elsewhere,
            )
            for (a in actions) when (a) {
                is AimCoach.Action.Say -> {
                    _spoken.value = a.text
                    speaker.speak(a.text)
                }
                is AimCoach.Action.StartCountdown -> countdownAndShoot()
                is AimCoach.Action.CancelCountdown -> Unit
            }
            if (upright != bitmap) upright.recycle()
        } catch (e: Exception) {
            Log.e(TAG, "analyze failed", e)
        } finally {
            image.close()
        }
    }

    private var letterboxBitmap: Bitmap? = null
    private val letterboxMatrix = Matrix()
    private val letterboxPaint = Paint(Paint.FILTER_BITMAP_FLAG)

    private fun detect(d: YoloDetector, upright: Bitmap, focus: IntArray? = null): List<Detection> {
        val dstW = d.inputWidth
        val dstH = d.inputHeight
        var target = letterboxBitmap
        if (target == null || target.width != dstW || target.height != dstH) {
            target = Bitmap.createBitmap(dstW, dstH, Bitmap.Config.ARGB_8888)
            letterboxBitmap = target
        }
        val scale = min(dstW.toFloat() / upright.width, dstH.toFloat() / upright.height)
        val padX = (dstW - upright.width * scale) / 2f
        val padY = (dstH - upright.height * scale) / 2f
        val canvas = Canvas(target)
        canvas.drawColor(android.graphics.Color.BLACK)
        letterboxMatrix.reset()
        letterboxMatrix.postScale(scale, scale)
        letterboxMatrix.postTranslate(padX, padY)
        canvas.drawBitmap(upright, letterboxMatrix, letterboxPaint)
        val info = LetterboxInfo(scale, padX, padY, upright.width, upright.height)
        return d.detect(target, info, focusClassIds = focus)
    }

    private fun rotateUpright(src: Bitmap, rotationDegrees: Int): Bitmap {
        if (rotationDegrees % 360 == 0) return src
        val m = Matrix().apply { postRotate(rotationDegrees.toFloat()) }
        return Bitmap.createBitmap(src, 0, 0, src.width, src.height, m, true)
    }

    // MARK: - Countdown and the burst

    private fun countdownAndShoot() {
        if (_shooting.value) return
        _shooting.value = true
        scope.launch {
            speaker.prepareToSpeak(timeoutMs = 6000)   // voice awake so "three" is heard
            for (word in AimPhrases.countdown) {
                _countdownWord.value = word
                _spoken.value = word
                speaker.speakAndWait(word, timeoutMs = 1200)
                delay(220)
            }
            _countdownWord.value = null
            val frames = ArrayList<Pair<ByteArray, Double>>()
            repeat(BURST) {
                val jpeg = takeOne() ?: return@repeat
                val bmp = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
                if (bmp != null) {
                    frames.add(jpeg to AimVision.sharpness(bmp))
                    bmp.recycle()
                }
            }
            finish(frames)
        }
    }

    private suspend fun takeOne(): ByteArray? = withContext(Dispatchers.IO) {
        val out = ByteArrayOutputStream()
        var result: ByteArray? = null
        val latch = java.util.concurrent.CountDownLatch(1)
        imageCapture.takePicture(
            ContextCompat.getMainExecutor(appContext),
            object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: ImageProxy) {
                    try {
                        val buffer = image.planes[0].buffer
                        val bytes = ByteArray(buffer.remaining())
                        buffer.get(bytes)
                        out.write(bytes)
                        result = out.toByteArray()
                    } catch (e: Exception) {
                        Log.e(TAG, "capture read failed", e)
                    } finally {
                        image.close()
                        latch.countDown()
                    }
                }

                override fun onError(exception: ImageCaptureException) {
                    Log.e(TAG, "capture failed", exception)
                    latch.countDown()
                }
            },
        )
        latch.await(6, java.util.concurrent.TimeUnit.SECONDS)
        result
    }

    /**
     * Keep exactly ONE photo: the best framed and sharpest of the burst, cropped
     * so the subject sits where a photographer would put it. Matt's rule
     * (2026-09-16): the other burst frames are discarded, never saved.
     */
    private suspend fun finish(frames: List<Pair<ByteArray, Double>>) {
        val s = subject
        if (frames.isEmpty() || s == null) {
            say(AimPhrases.captureFailed)
            _shooting.value = false
            coach?.countdownEnded()
            return
        }
        val box = coach?.smoothedBox
        val scored = frames.map { AimBurst.Frame(box, it.second) }
        val index = AimBurst.pick(scored, s.framing) ?: 0
        val jpeg = frames[index].first
        val savedUri = withContext(Dispatchers.IO) { saveOne(jpeg, box, s) }
        val saved = savedUri != null
        _lastPhoto.value = withContext(Dispatchers.IO) {
            // A small copy for the Picture Taken screen; the full one is in the
            // camera roll.
            BitmapFactory.decodeByteArray(
                jpeg, 0, jpeg.size,
                BitmapFactory.Options().apply { inSampleSize = 4 },
            )
        }
        _shooting.value = false
        coach?.countdownEnded()
        val shot = ++shotNumber

        // The photo is saved with its description written into it (AppleVis
        // user "Matt", 2026-09-15), same words as the iPhone. Android saves
        // first and captions after, because the model can take a minute on a
        // slow phone and the picture must not wait on it.
        var description: String? = null
        if (withContext(Dispatchers.IO) { narrator.hasModel() }) {
            say(AimPhrases.describing)
            _done.value = AimPhrases.capitalized(AimPhrases.describing)
            description = withContext(Dispatchers.IO) {
                AimCaption.describe(appContext, narrator, jpeg, s is AimSubject.Page)
            }
            if (description != null && savedUri != null) {
                withContext(Dispatchers.IO) { AimCaption.embed(appContext, savedUri, description) }
            }
        }
        // Taking another or leaving must not be talked over.
        if (shot != shotNumber) return
        val line = if (description != null) {
            description + " " + AimPhrases.capitalized(
                if (saved) AimPhrases.savedWithDescription else AimPhrases.notSavedWithDescription,
            ) + "."
        } else {
            AimPhrases.capitalized(
                AimPhrases.pictureTaken + if (saved) AimPhrases.savedSuffix else AimPhrases.notSavedSuffix,
            )
        }
        say(line)
        _done.value = line
    }

    /** Aim at the same thing again (iOS "Take Another"). */
    fun takeAnother() {
        val s = subject ?: return
        shotNumber++
        _done.value = null
        _lastPhoto.value = null
        aimAt(s)
    }

    private fun saveOne(jpeg: ByteArray, box: AimRect?, s: AimSubject): Uri? {
        try {
            var bitmap = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return null
            // Kareen, 2026-09-25: a picture shot at an angle is kept as the
            // picture itself, squared up, when its four edges can be found.
            val flat = if (s is AimSubject.Page && box != null) squareUpPage(bitmap, box) else null
            if (flat != null) {
                if (flat !== bitmap) bitmap.recycle()
                bitmap = flat
            } else if (box != null) {
                val crop = AimBurst.crop(
                    box, bitmap.width.toFloat(), bitmap.height.toFloat(), s.framing,
                )
                if (crop != null) {
                    val x = crop.minX.roundToInt().coerceIn(0, bitmap.width - 1)
                    val y = crop.minY.roundToInt().coerceIn(0, bitmap.height - 1)
                    val w = crop.width.roundToInt().coerceAtMost(bitmap.width - x)
                    val h = crop.height.roundToInt().coerceAtMost(bitmap.height - y)
                    if (w > 0 && h > 0) {
                        val cropped = Bitmap.createBitmap(bitmap, x, y, w, h)
                        if (cropped !== bitmap) bitmap.recycle()
                        bitmap = cropped
                    }
                }
            }
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, "RTCam-${System.currentTimeMillis()}.jpg")
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/RealTime AI Cam")
                }
            }
            val uri = appContext.contentResolver
                .insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            if (uri == null) {
                bitmap.recycle()
                return null
            }
            appContext.contentResolver.openOutputStream(uri)?.use {
                bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it)
            }
            bitmap.recycle()
            return uri
        } catch (e: Exception) {
            Log.e(TAG, "save failed", e)
            return null
        }
    }

    /** The page inside [box] squared up, or null when its edges are not clear. */
    private fun squareUpPage(bitmap: Bitmap, box: AimRect): Bitmap? {
        return try {
            val scale = AimQuadFinder.analysisSide / max(bitmap.width, bitmap.height).toFloat()
            val w = max(8, (bitmap.width * scale).roundToInt())
            val h = max(8, (bitmap.height * scale).roundToInt())
            val small = Bitmap.createScaledBitmap(bitmap, w, h, true)
            val px = IntArray(w * h)
            small.getPixels(px, 0, w, 0, 0, w, h)
            if (small !== bitmap) small.recycle()
            val gray = FloatArray(w * h) { i ->
                val p = px[i]
                0.299f * ((p shr 16) and 0xFF) + 0.587f * ((p shr 8) and 0xFF) + 0.114f * (p and 0xFF)
            }
            val q = AimQuadFinder.find(gray, w, h, box) ?: return null
            val W = bitmap.width.toFloat()
            val H = bitmap.height.toFloat()
            if (!AimStraighten.usable(q, W, H)) return null
            val (ow, oh) = AimStraighten.outputSize(q, W, H)
            val src = floatArrayOf(
                q.topLeft.x * W, q.topLeft.y * H, q.topRight.x * W, q.topRight.y * H,
                q.bottomRight.x * W, q.bottomRight.y * H, q.bottomLeft.x * W, q.bottomLeft.y * H,
            )
            val dst = floatArrayOf(0f, 0f, ow, 0f, ow, oh, 0f, oh)
            val m = android.graphics.Matrix()
            if (!m.setPolyToPoly(src, 0, dst, 0, 4)) return null
            val out = Bitmap.createBitmap(ow.roundToInt(), oh.roundToInt(), Bitmap.Config.ARGB_8888)
            android.graphics.Canvas(out).drawBitmap(
                bitmap, m, android.graphics.Paint(android.graphics.Paint.FILTER_BITMAP_FLAG),
            )
            out
        } catch (e: Throwable) {
            Log.e(TAG, "square up failed", e)
            null
        }
    }

    private fun say(text: String) {
        _spoken.value = text
        speaker.speak(text)
    }

    /** Take the picture without waiting for the coach (double tap). */
    fun shootNow() {
        if (!_shooting.value) countdownAndShoot()
    }
}

fun nowSeconds(): Double = SystemClock.elapsedRealtime() / 1000.0
