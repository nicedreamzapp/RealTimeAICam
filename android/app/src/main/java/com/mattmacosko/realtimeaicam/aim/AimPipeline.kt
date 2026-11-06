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
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.isActive
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
        lookJob?.cancel()
        if (s is AimSubject.Described) startLooking(s.word, firstWaitMs = 5000)
    }

    /** True when the describing model is on this phone (Help Me Aim's backup). */
    fun canDescribe(): Boolean = narrator.hasModel()

    /** This phone's seconds per look with the scene model, or null before the first answer. */
    fun lookSeconds(): Int? = com.mattmacosko.realtimeaicam.narrator.ModelPicker.estimate(
        appContext,
        com.mattmacosko.realtimeaicam.narrator.ModelPicker.level(appContext, com.mattmacosko.realtimeaicam.narrator.PhotoKind.SCENE),
        com.mattmacosko.realtimeaicam.narrator.PhotoKind.SCENE,
    )?.let { kotlin.math.round(it).toInt() }

    private var lookJob: Job? = null

    /**
     * The describing model looks at one photo at a time and steers toward the
     * thing; a "yes, in the middle" counts down and takes the picture.
     */
    private fun startLooking(word: String, firstWaitMs: Long) {
        lookJob?.cancel()
        lookJob = scope.launch {
            delay(firstWaitMs)
            var misses = 0
            var steers = 0
            var sure: Boolean? = null
            var saidWhyNoPhoto = false
            while (isActive && misses < AimAsk.MAX_MISSES) {
                if (_shooting.value || subject !is AimSubject.Described) return@launch
                val jpeg = (if (AimFake.word != null) AimFake.next() else null) ?: takeOne()
                if (jpeg == null) {
                    if (!saidWhyNoPhoto) {
                        saidWhyNoPhoto = true
                        Log.w(TAG, "no photo to look at: ${noPhotoWhy ?: "unknown"}")
                    }
                    misses++; delay(1000); continue
                }
                val answer = withContext(Dispatchers.IO) { askAbout(jpeg, AimAsk.question(word)) }
                if (!isActive || subject !is AimSubject.Described || _shooting.value) return@launch
                Log.i(TAG, "[ask] $word -> $answer")
                val r = AimAsk.read(answer)
                if (r.found) {
                    misses = 0
                    if (sure == null) {
                        val listing = withContext(Dispatchers.IO) { askAbout(jpeg, AimAsk.CONFIRM_QUESTION) }
                        if (!isActive) return@launch
                        sure = AimAsk.confirms(word, listing)
                        Log.i(TAG, "[ask] confirm $word sure=$sure -> $listing")
                    }
                    val place = r.place
                    if (place == null || place == AimAsk.Place.MIDDLE || steers >= AimAsk.MAX_STEERS) {
                        val line = if (sure == true) AimAsk.FOUND else AimAsk.FOUND_UNSURE
                        _spoken.value = line
                        Log.i(TAG, "SAY $line")
                        speaker.speakAndWait(line, timeoutMs = 8000)
                        if (isActive && subject is AimSubject.Described) countdownAndShoot()
                        return@launch
                    }
                    steers++
                    val line = AimAsk.steer(place)
                    _spoken.value = line
                    Log.i(TAG, "SAY $line")
                    speaker.speakAndWait(line, timeoutMs = 6000)
                } else {
                    misses++
                    AimAsk.notYet(word, misses)?.let {
                        _spoken.value = it
                        Log.i(TAG, "SAY $it")
                        speaker.speakAndWait(it, timeoutMs = 5000)
                    }
                }
                delay(1200)
            }
            if (isActive && subject is AimSubject.Described && !_shooting.value) {
                val line = AimAsk.gaveUp(word)
                _spoken.value = line
                speaker.speak(line)
            }
        }
    }

    /** Blocking. The describing model's answer to [question] about [jpeg]. */
    private fun askAbout(jpeg: ByteArray, question: String): String? = try {
        val raw = java.io.File(appContext.cacheDir, "aim-ask-raw.jpg").apply { writeBytes(jpeg) }
        val shot = java.io.File(appContext.cacheDir, "aim-ask.jpg")
        if (com.mattmacosko.realtimeaicam.ui.prepareShot(raw, shot) == null) {
            null
        } else {
            narrator.select(com.mattmacosko.realtimeaicam.narrator.ModelPicker.level(
                appContext, com.mattmacosko.realtimeaicam.narrator.PhotoKind.SCENE))
            val sized = com.mattmacosko.realtimeaicam.ui.sizedForModel(appContext, shot, false)
            narrator.describe(sized, question, com.mattmacosko.realtimeaicam.narrator.NarratorPrompt.ASK).trim().ifBlank { null }
        }
    } catch (t: Throwable) {
        Log.e(TAG, "ask failed", t)
        null
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
                (subject as? AimSubject.Described)?.let {
                    if (lookJob?.isActive != true && !_shooting.value) startLooking(it.word, firstWaitMs = 2000)
                }
                // A rebind drops the torch, so put it back if it was on.
                if (_torchOn.value && !_isFront.value) camera?.cameraControl?.enableTorch(true)
            } catch (e: Exception) {
                Log.e(TAG, "camera bind failed", e)
            }
        }, ContextCompat.getMainExecutor(appContext))
    }

    /**
     * Flashlight. Only the back camera has one, same as the iPhone, and the app
     * says "flashlight on" / "flashlight off" in those exact words (in the app's language).
     */
    fun toggleTorch(): String {
        val on = !_torchOn.value && !_isFront.value
        _torchOn.value = on
        camera?.cameraControl?.enableTorch(on)
        return com.mattmacosko.realtimeaicam.AppLang.str(
            if (on) com.mattmacosko.realtimeaicam.R.string.g_aim_flashlight_on else com.mattmacosko.realtimeaicam.R.string.g_aim_flashlight_off,
        )
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
        return com.mattmacosko.realtimeaicam.AppLang.str(
            if (_isFront.value) com.mattmacosko.realtimeaicam.R.string.g_aim_front_camera else com.mattmacosko.realtimeaicam.R.string.g_aim_back_camera,
        )
    }

    fun stop() {
        lookJob?.cancel()
        lookJob = null
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
            // The describing model does the looking; no detector frames.
            if (s is AimSubject.Described) return
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

    /** Why the last takeOne() came back empty, logged once per look (2026-11-04). */
    @Volatile private var noPhotoWhy: String? = null

    private suspend fun takeOne(): ByteArray? = withContext(Dispatchers.IO) {
        if (AimFake.word != null) {
            return@withContext AimFake.last().also {
                if (it == null) noPhotoWhy = "test photos: 0 frames in ${AimFake.dirs}"
            }
        }
        if (camera == null) {
            noPhotoWhy = "camera not bound"
            return@withContext null
        }
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
                    noPhotoWhy = "capture failed: ${exception.message}"
                    latch.countDown()
                }
            },
        )
        if (!latch.await(6, java.util.concurrent.TimeUnit.SECONDS)) {
            noPhotoWhy = "capture timed out after 6 s (camera unbound or busy)"
        }
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
        val savedUri = if (AimFake.word != null) null else withContext(Dispatchers.IO) { saveOne(jpeg, box, s) }
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
        val savedLine = AimPhrases.capitalized(
            if (saved) AimPhrases.savedWithDescription else AimPhrases.notSavedWithDescription,
        )
        val app = com.mattmacosko.realtimeaicam.AppLang.code()
        if (description != null && app != com.mattmacosko.realtimeaicam.AppLang.ENGLISH) {
            // Spanish app (2026-11-05): the saved line is already Spanish, the description is
            // the model's English (content). Put the description into the same language when
            // that pack is on the phone and say both as one line in one voice; otherwise the
            // description is said in its own language and the saved line after it.
            val said = if (speaker.outputLanguage() == app) {
                withContext(Dispatchers.IO) {
                    com.mattmacosko.realtimeaicam.translation.YourLanguage.translateBlocking(description, "en", app)
                }
            } else {
                null
            }
            if (shot != shotNumber) return
            if (said != null) {
                val line = "$said $savedLine."
                Log.i(TAG, "SAY $line")
                _spoken.value = line
                speaker.speakIn(line, app, result = true)
                _done.value = line
            } else {
                val line = "$description $savedLine."
                Log.i(TAG, "SAY $line")
                _spoken.value = line
                _done.value = line
                val aloud = appContext.getSharedPreferences("rtcam", Context.MODE_PRIVATE)
                    .getBoolean("speakAnswersAloud", true)
                if (aloud) {
                    speaker.speakResult(description)
                    sayWhenQuiet("$savedLine.", shot)
                } else {
                    // TalkBack reads it in the person's own voice: one announcement, nothing cut off.
                    speaker.speakResult(line)
                }
            }
            return
        }
        val line = if (description != null) {
            "$description $savedLine."
        } else {
            AimPhrases.capitalized(AimPhrases.pictureTaken(saved))
        }
        Log.i(TAG, "SAY $line")
        _spoken.value = line
        // A description read to the end is a success moment for the rating card.
        if (description != null) speaker.speakResult(line) else speaker.speak(line)
        _done.value = line
    }

    /**
     * Say an app line once the voice has finished the line before it (a description in
     * another language). Gives up waiting after a while so the line is never lost, and stays
     * quiet if another shot was started meanwhile.
     */
    private suspend fun sayWhenQuiet(line: String, shot: Int) {
        val start = SystemClock.elapsedRealtime()
        // The description may still be in the translator: wait for the voice to start...
        while (!speaker.speakingNow.value && SystemClock.elapsedRealtime() - start < 4000) delay(50)
        // ...and to finish.
        while (speaker.speakingNow.value && SystemClock.elapsedRealtime() - start < 180_000) delay(100)
        if (shot != shotNumber) return
        speaker.speak(line)
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


/**
 * Test builds only: `-e aimFakeFind <word>` opens Help Me Aim on that word and
 * feeds the .jpg files in files/photo-test/flow, in order, as the camera, one photo per
 * look (the last one repeats, and is the burst). Nothing is saved to the
 * gallery. Lets a phone walk the describing-model flow unaimed (2026-11-03).
 */
object AimFake {
    @Volatile var word: String? = null
        private set
    private var frames: List<ByteArray> = emptyList()
    private var shown = 0

    /** Where setUp looked, for the log line when no frames load. */
    @Volatile var dirs: String = ""
        private set

    /**
     * Reads files/photo-test/flow FIRST (push with `adb shell run-as <pkg>`):
     * on Android 13 files adb-pushed into the external app dir belong to the
     * shell user and the app gets Permission denied. Falls back to the
     * external dir (older phones). 2026-11-04.
     */
    fun setUp(context: android.content.Context, word: String) {
        val candidates = listOfNotNull(
            java.io.File(context.filesDir, "photo-test/flow"),
            context.getExternalFilesDir(null)?.let { java.io.File(it, "photo-test/flow") },
        )
        dirs = candidates.joinToString(" or ") { it.path }
        var loaded: List<ByteArray> = emptyList()
        var from = "none"
        for (dir in candidates) {
            val files = (dir.listFiles() ?: emptyArray()).filter { it.name.endsWith(".jpg") }
                .sortedBy { it.name }
            val bytes = files.mapNotNull { f ->
                try { f.readBytes() } catch (e: Exception) {
                    android.util.Log.w("AimPipeline", "AimFake: cannot read ${f.path}: ${e.message}")
                    null
                }
            }
            if (bytes.isNotEmpty()) { loaded = bytes; from = dir.path; break }
        }
        frames = loaded
        android.util.Log.i("AimPipeline", "AimFake: ${frames.size} frames from $from (looked in $dirs)")
        shown = 0
        this.word = word
    }

    @Synchronized fun next(): ByteArray? {
        if (frames.isEmpty()) return null
        return frames[minOf(shown++, frames.size - 1)]
    }

    @Synchronized fun last(): ByteArray? =
        if (frames.isEmpty()) null else frames[minOf(maxOf(shown - 1, 0), frames.size - 1)]
}
