package com.mattmacosko.realtimeaicam.aim

import android.graphics.Bitmap
import android.graphics.RectF
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.mattmacosko.realtimeaicam.detection.Detection
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import kotlin.math.max
import kotlin.math.min

/**
 * The Android half of Help Me Aim's eyes.
 *
 * iOS uses Apple's Vision framework for faces and a CoreML detector for
 * everything else. Android uses ML Kit for faces and the YOLOv8n-oiv7 detector
 * the app already ships. The DECISIONS are identical — they all live in
 * HelpMeAim.kt, which is a straight port of the iPhone's HelpMeAim.swift — so
 * only the measuring differs.
 *
 * One honest difference to know about: iOS looks up a spoken word in YOLOE's
 * 4,585 names; Android looks it up in this detector's 601. So "Something Else"
 * understands fewer words here, and says so plainly ("I can't look for X yet")
 * rather than pretending. Same sentence the iPhone uses when its own lookup
 * fails.
 */
object AimVision {

    /** Everything one analysed frame tells the coach. */
    data class Look(
        /** The subject's box, upright and normalized, or null if not in view. */
        val box: AimRect?,
        /** How many faces are in view (face mode only; 1 otherwise). */
        val faceCount: Int,
        /** Everything the detector saw, for the "I can see ..." sentence. */
        val seen: List<AimElsewhere.Seen>,
    )

    private val faceDetector by lazy {
        FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                // Fast: this runs on every analysed frame on phones as weak as a
                // Helio P35, and the box is all Help Me Aim needs — no landmarks,
                // no contours, no smile.
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_NONE)
                .setContourMode(FaceDetectorOptions.CONTOUR_MODE_NONE)
                .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_NONE)
                .setMinFaceSize(0.08f)
                .build(),
        )
    }

    fun toAimRect(r: RectF, width: Int, height: Int): AimRect? {
        if (width <= 0 || height <= 0) return null
        val l = max(0f, min(1f, r.left / width))
        val t = max(0f, min(1f, r.top / height))
        val rt = max(0f, min(1f, r.right / width))
        val b = max(0f, min(1f, r.bottom / height))
        if (rt <= l || b <= t) return null
        return AimRect.fromEdges(l, t, rt, b)
    }

    /** Detector boxes are already normalized to the upright frame. */
    fun toAimRect(r: RectF): AimRect? {
        if (r.right <= r.left || r.bottom <= r.top) return null
        return AimRect.fromEdges(
            max(0f, min(1f, r.left)), max(0f, min(1f, r.top)),
            max(0f, min(1f, r.right)), max(0f, min(1f, r.bottom)),
        )
    }

    /**
     * The biggest face in the frame, plus how many there are. The biggest is the
     * one being aimed at — same choice the iPhone makes.
     */
    suspend fun faces(bitmap: Bitmap): Pair<AimRect?, Int> = suspendCoroutine { cont ->
        val image = InputImage.fromBitmap(bitmap, 0)
        faceDetector.process(image)
            .addOnSuccessListener { found ->
                val boxes = found.mapNotNull { toAimRect(RectF(it.boundingBox), bitmap.width, bitmap.height) }
                val biggest = boxes.maxByOrNull { it.width * it.height }
                cont.resume(biggest to boxes.size)
            }
            .addOnFailureListener { cont.resume(null to 0) }
    }

    /** Classes that count as "a picture or page" when Picture or Page is chosen. */
    val pageClasses: Set<String> = setOf(
        "poster", "picture frame", "photo frame", "book", "paper", "document", "envelope",
        "newspaper", "magazine", "whiteboard", "poster board", "painting", "oil painting",
        "watercolor painting", "advertisement", "receipt", "letter", "menu",
    )

    /** The subject box for a page, chosen the same way the iPhone chooses it. */
    fun pageBox(detections: List<Detection>): AimRect? {
        val backup = detections
            .filter { pageClasses.contains(it.className.lowercase()) }
            .maxByOrNull { (it.rect.right - it.rect.left) * (it.rect.bottom - it.rect.top) }
            ?.let { toAimRect(it.rect) }
        // Android has no document-segmentation equivalent to Apple's Vision
        // request, so there is no `document` and no rectangle list to support;
        // the detector's own page-ish box is the answer. AimPage.choose still
        // runs so the two phones take the same path when a document finder is
        // added here later.
        return AimPage.choose(document = null, rectangles = emptyList(), backup = backup)
    }

    /** The subject box for a named thing. */
    fun objectBox(detections: List<Detection>, match: AimVocabulary.Match): AimRect? {
        val wanted = match.classNames.map { it.lowercase() }.toSet()
        return detections
            .filter { wanted.contains(it.className.lowercase()) }
            .maxByOrNull { it.score }
            ?.let { toAimRect(it.rect) }
    }

    /** Everything worth mentioning in "I don't see X. I can see ..." */
    fun seen(detections: List<Detection>): List<AimElsewhere.Seen> =
        detections.mapNotNull { d ->
            toAimRect(d.rect)?.let { AimElsewhere.Seen(d.className, d.score, it) }
        }

    /**
     * Variance of the Laplacian on a small grayscale copy — the same sharpness
     * number the iPhone's FrameQualityGate feeds to AimBurst, so the burst picks
     * the same frame on both phones.
     */
    fun sharpness(bitmap: Bitmap, longSide: Int = 256): Double {
        val scale = longSide.toFloat() / max(bitmap.width, bitmap.height)
        val w = max(3, (bitmap.width * scale).toInt())
        val h = max(3, (bitmap.height * scale).toInt())
        val small = Bitmap.createScaledBitmap(bitmap, w, h, true)
        val px = IntArray(w * h)
        small.getPixels(px, 0, w, 0, 0, w, h)
        if (small != bitmap) small.recycle()
        val gray = DoubleArray(w * h)
        for (i in px.indices) {
            val p = px[i]
            gray[i] = 0.299 * ((p shr 16) and 0xFF) + 0.587 * ((p shr 8) and 0xFF) + 0.114 * (p and 0xFF)
        }
        var sum = 0.0
        var sumSq = 0.0
        var n = 0
        for (y in 1 until h - 1) {
            for (x in 1 until w - 1) {
                val i = y * w + x
                val lap = -4 * gray[i] + gray[i - 1] + gray[i + 1] + gray[i - w] + gray[i + w]
                sum += lap
                sumSq += lap * lap
                n++
            }
        }
        if (n == 0) return 0.0
        val mean = sum / n
        return sumSq / n - mean * mean
    }
}
