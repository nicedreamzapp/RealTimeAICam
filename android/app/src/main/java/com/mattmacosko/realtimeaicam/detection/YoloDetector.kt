package com.mattmacosko.realtimeaicam.detection

import android.content.Context
import android.graphics.Bitmap
import android.graphics.RectF
import android.os.SystemClock
import android.util.Log
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.CompatibilityList
import org.tensorflow.lite.gpu.GpuDelegate
import java.io.FileNotFoundException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel
import kotlin.math.max
import kotlin.math.min

/**
 * Runtime configuration for the detector (also drives on-device benchmarking).
 *
 * Defaults were benchmarked on an MT6765 (8x A53 + PowerVR GE8320):
 *   cpu/4t/fp16 ~1630ms, cpu/8t/fp16 ~1660ms, cpu/4t/fp32 ~1630ms,
 *   gpu/fp16 ~870ms, gpu/fp32 ~690ms  -> GPU delegate + fp32 model wins.
 * (The fp32 model is faster on the GPU delegate: fp16-weight models insert
 * dequantize ops, while fp32 weights are converted to fp16 GPU precision
 * directly.) CPU/XNNPACK remains the automatic fallback.
 */
data class DetectorConfig(
    val modelAsset: String = YoloDetector.MODEL_ASSET_FP32,
    /** "cpu" (XNNPACK) or "gpu" (GPU delegate with CPU fallback). */
    val backend: String = "gpu",
    val numThreads: Int = 4,
)

/**
 * Port of the iOS YOLOv8Processor (project 601) decode pipeline to TFLite.
 *
 * Thresholds match the iOS implementation:
 *  - base confidence threshold 0.20 scaled by a user threshold (default 0.75 -> 0.15 effective)
 *  - per-class NMS IoU 0.45
 *  - class-agnostic duplicate suppression IoU 0.90
 *  - max 40 detections per frame, 150 raw candidates
 *
 * The decoder reads the interpreter's output shape at runtime and supports both
 * [1, C, A] (channels-first, ultralytics default: [1, 605, 8400]) and [1, A, C]
 * layouts, and both normalized 0-1 and pixel-space xywh center coordinates.
 *
 * Performance notes (matters a lot on little cores like the MT6765's A53s):
 *  - the output tensor is bulk-copied once into a FloatArray, then the
 *    per-anchor class argmax streams through it sequentially (class-major for
 *    [1,C,A]) instead of ~5M strided FloatBuffer.get() calls per frame
 *  - input fill goes through a reused FloatArray + one bulk put
 */
class YoloDetector private constructor(
    private val interpreter: Interpreter,
    private val gpuDelegate: GpuDelegate?,
    val classNames: List<String>,
    val backendDescription: String,
) {
    companion object {
        private const val TAG = "YoloDetector"
        const val MODEL_ASSET_FP16 = "yolov8n_oiv7_fp16.tflite"
        const val MODEL_ASSET_FP32 = "yolov8n_oiv7_fp32.tflite"
        const val LABELS_ASSET = "class_names.txt"

        private const val BASE_THRESHOLD = 0.20f
        private const val DEFAULT_USER_THRESHOLD = 0.75f
        private const val IOU_THRESHOLD = 0.45f
        private const val DUPLICATE_IOU_THRESHOLD = 0.90f
        private const val MAX_DETECTIONS_PER_FRAME = 40
        private const val MAX_RAW_DETECTIONS = 150
        private const val PERF_LOG_EVERY = 10

        /**
         * Creates the detector, or throws with a human-readable message when the
         * model asset is missing (the app shows the message instead of crashing).
         */
        @Throws(Exception::class)
        fun create(context: Context, config: DetectorConfig = DetectorConfig()): YoloDetector {
            val modelBuffer = try {
                loadModelFile(context, config.modelAsset)
            } catch (e: FileNotFoundException) {
                throw IllegalStateException(
                    "Model asset \"${config.modelAsset}\" not found in APK assets.\n" +
                        "Export yolov8n-oiv7 to TFLite and copy it (plus $LABELS_ASSET) " +
                        "into app/src/main/assets/, then rebuild."
                )
            }

            var gpuDelegate: GpuDelegate? = null
            var backend: String

            val options = Interpreter.Options()
            if (config.backend == "gpu") {
                backend = try {
                    val compatList = CompatibilityList()
                    gpuDelegate = if (compatList.isDelegateSupportedOnThisDevice) {
                        GpuDelegate(compatList.bestOptionsForThisDevice)
                    } else {
                        Log.w(TAG, "GPU delegate not in compatibility list; trying default options")
                        GpuDelegate()
                    }
                    options.addDelegate(gpuDelegate)
                    "gpu"
                } catch (e: Throwable) {
                    Log.w(TAG, "GPU delegate init failed, falling back to CPU", e)
                    gpuDelegate?.close()
                    gpuDelegate = null
                    "cpu-fallback"
                }
            } else {
                backend = "cpu"
            }
            // CPU path settings (also used for ops the GPU delegate rejects)
            options.numThreads = config.numThreads
            options.setUseXNNPACK(true)

            val interpreter = try {
                Interpreter(modelBuffer, options)
            } catch (e: Throwable) {
                if (gpuDelegate != null) {
                    // GPU delegate refused the graph -> retry pure CPU
                    Log.w(TAG, "Interpreter init with GPU delegate failed, retrying CPU", e)
                    gpuDelegate.close()
                    gpuDelegate = null
                    backend = "cpu-fallback"
                    val cpuOptions = Interpreter.Options().apply {
                        numThreads = config.numThreads
                        setUseXNNPACK(true)
                    }
                    Interpreter(modelBuffer, cpuOptions)
                } else {
                    throw e
                }
            }

            val modelTag = config.modelAsset.substringAfterLast('_').removeSuffix(".tflite")
            val description = "$backend/${config.numThreads}t/$modelTag"
            val classNames = loadClassNames(context)
            return YoloDetector(interpreter, gpuDelegate, classNames, description)
        }

        private fun loadModelFile(context: Context, assetName: String): MappedByteBuffer {
            context.assets.openFd(assetName).use { fd ->
                java.io.FileInputStream(fd.fileDescriptor).use { input ->
                    return input.channel.map(
                        FileChannel.MapMode.READ_ONLY,
                        fd.startOffset,
                        fd.declaredLength
                    )
                }
            }
        }

        private fun loadClassNames(context: Context): List<String> {
            return try {
                context.assets.open(LABELS_ASSET).bufferedReader().useLines { lines ->
                    lines.map { it.trim() }.filter { it.isNotEmpty() }.toList()
                }
            } catch (e: Exception) {
                Log.w(TAG, "No $LABELS_ASSET in assets; using generic class names")
                emptyList()
            }
        }
    }

    // ---- Tensor geometry (read at runtime) ----

    private val inputTensor = interpreter.getInputTensor(0)
    private val inputShape: IntArray = inputTensor.shape() // e.g. [1, 640, 640, 3]
    private val inputIsNchw = inputShape.size == 4 && inputShape[1] == 3
    val inputHeight = if (inputIsNchw) inputShape[2] else inputShape[1]
    val inputWidth = if (inputIsNchw) inputShape[3] else inputShape[2]
    private val inputIsFloat = inputTensor.dataType() == DataType.FLOAT32

    private val outputTensor = interpreter.getOutputTensor(0)
    private val outputShape: IntArray = outputTensor.shape() // [1, C, A] or [1, A, C]

    /** True when the layout is [1, C, A] (channels first). */
    private val channelsFirst: Boolean
    private val numChannels: Int // 4 + numClasses
    private val numAnchors: Int
    private val numClasses: Int

    val outputShapeString: String = outputShape.joinToString(prefix = "[", postfix = "]")

    init {
        require(outputShape.size == 3 && outputShape[0] == 1) {
            "Unexpected YOLO output shape $outputShapeString"
        }
        val d1 = outputShape[1]
        val d2 = outputShape[2]
        // Prefer the dimension that equals 4 + known class count; otherwise the
        // smaller dimension is the channel dimension (605 << 8400).
        val expectedChannels = if (classNames.isNotEmpty()) classNames.size + 4 else -1
        channelsFirst = when {
            d1 == expectedChannels -> true
            d2 == expectedChannels -> false
            else -> d1 < d2
        }
        numChannels = if (channelsFirst) d1 else d2
        numAnchors = if (channelsFirst) d2 else d1
        numClasses = numChannels - 4
        Log.i(
            TAG,
            "Model loaded. backend=$backendDescription input=${inputShape.joinToString("x")} " +
                "float=$inputIsFloat output=$outputShapeString " +
                "layout=${if (channelsFirst) "[1,C,A]" else "[1,A,C]"} " +
                "anchors=$numAnchors classes=$numClasses labels=${classNames.size}"
        )
    }

    // ---- Reusable buffers (single inference thread; detect() is synchronized) ----

    private val inputBuffer: ByteBuffer = ByteBuffer
        .allocateDirect(inputWidth * inputHeight * 3 * (if (inputIsFloat) 4 else 1))
        .order(ByteOrder.nativeOrder())
    private val pixelBuffer = IntArray(inputWidth * inputHeight)
    private val inputFloats = if (inputIsFloat) FloatArray(inputWidth * inputHeight * 3) else FloatArray(0)
    private val inputBytes = if (!inputIsFloat) ByteArray(inputWidth * inputHeight * 3) else ByteArray(0)

    private val outputBuffer: ByteBuffer = ByteBuffer
        .allocateDirect(numChannels * numAnchors * 4)
        .order(ByteOrder.nativeOrder())
    private val outputFloats: FloatBuffer = outputBuffer.asFloatBuffer()
    private val outputArray = FloatArray(numChannels * numAnchors)
    private val bestScores = FloatArray(numAnchors)
    private val bestClasses = IntArray(numAnchors)

    /** Whether xywh come out in pixel space (vs normalized 0-1); decided on first frame. */
    private var coordsArePixels: Boolean? = null

    private var frameIndex = 0

    private fun coord(channel: Int, anchor: Int): Float =
        if (channelsFirst) outputArray[channel * numAnchors + anchor]
        else outputArray[anchor * numChannels + channel]

    private fun className(index: Int): String =
        if (index in classNames.indices) classNames[index] else "Class_$index"

    /**
     * Runs inference on an already-letterboxed [inputWidth]x[inputHeight] bitmap.
     * Returns detections with rects normalized 0..1 relative to the ORIGINAL
     * (pre-letterbox) upright frame described by [letterbox].
     */
    @Synchronized
    fun detect(
        letterboxed: Bitmap,
        letterbox: LetterboxInfo,
        userConfidenceThreshold: Float = DEFAULT_USER_THRESHOLD,
    ): List<Detection> {
        val t0 = SystemClock.elapsedRealtime()
        fillInput(letterboxed)
        val t1 = SystemClock.elapsedRealtime()
        outputBuffer.rewind()
        interpreter.run(inputBuffer, outputBuffer)
        val t2 = SystemClock.elapsedRealtime()
        val result = decode(letterbox, userConfidenceThreshold)
        val t3 = SystemClock.elapsedRealtime()

        if (++frameIndex % PERF_LOG_EVERY == 0) {
            Log.i(
                TAG,
                "perf[$backendDescription] fill=${t1 - t0}ms run=${t2 - t1}ms " +
                    "decode=${t3 - t2}ms total=${t3 - t0}ms dets=${result.size}"
            )
        }
        return result
    }

    private fun fillInput(bitmap: Bitmap) {
        bitmap.getPixels(pixelBuffer, 0, inputWidth, 0, 0, inputWidth, inputHeight)
        inputBuffer.rewind()
        if (inputIsFloat) {
            val f = inputFloats
            if (inputIsNchw) {
                val n = inputWidth * inputHeight
                for (i in 0 until n) {
                    val px = pixelBuffer[i]
                    f[i] = ((px shr 16) and 0xFF) * (1f / 255f)
                    f[n + i] = ((px shr 8) and 0xFF) * (1f / 255f)
                    f[2 * n + i] = (px and 0xFF) * (1f / 255f)
                }
            } else {
                var j = 0
                for (px in pixelBuffer) {
                    f[j] = ((px shr 16) and 0xFF) * (1f / 255f)
                    f[j + 1] = ((px shr 8) and 0xFF) * (1f / 255f)
                    f[j + 2] = (px and 0xFF) * (1f / 255f)
                    j += 3
                }
            }
            inputBuffer.asFloatBuffer().put(f)
        } else {
            val b = inputBytes
            var j = 0
            for (px in pixelBuffer) {
                b[j] = ((px shr 16) and 0xFF).toByte()
                b[j + 1] = ((px shr 8) and 0xFF).toByte()
                b[j + 2] = (px and 0xFF).toByte()
                j += 3
            }
            inputBuffer.put(b)
        }
        inputBuffer.rewind()
    }

    /**
     * Cache-friendly per-anchor argmax over the class scores.
     * For [1,C,A] we stream class rows sequentially instead of striding.
     */
    private fun computeBestClasses() {
        val out = outputArray
        val scores = bestScores
        val classes = bestClasses
        if (channelsFirst) {
            val classBase = 4 * numAnchors
            System.arraycopy(out, classBase, scores, 0, numAnchors)
            java.util.Arrays.fill(classes, 0)
            var offset = classBase + numAnchors
            for (c in 1 until numClasses) {
                for (a in 0 until numAnchors) {
                    val v = out[offset + a]
                    if (v > scores[a]) {
                        scores[a] = v
                        classes[a] = c
                    }
                }
                offset += numAnchors
            }
        } else {
            for (a in 0 until numAnchors) {
                val base = a * numChannels + 4
                var bs = 0f
                var bc = 0
                for (c in 0 until numClasses) {
                    val v = out[base + c]
                    if (v > bs) {
                        bs = v
                        bc = c
                    }
                }
                scores[a] = bs
                classes[a] = bc
            }
        }
    }

    private fun decode(letterbox: LetterboxInfo, userThreshold: Float): List<Detection> {
        val threshold = BASE_THRESHOLD * max(0.04f, userThreshold)

        // One bulk copy out of the direct buffer, then plain array math.
        outputFloats.rewind()
        outputFloats.get(outputArray)

        computeBestClasses()

        // Decide once whether coordinates are normalized or pixel-space by
        // sampling the max center coordinate on the first decoded frame.
        if (coordsArePixels == null) {
            var maxCoord = 0f
            var a = 0
            while (a < numAnchors) {
                maxCoord = max(maxCoord, coord(0, a))
                maxCoord = max(maxCoord, coord(1, a))
                a += 37 // sparse sample is plenty
            }
            coordsArePixels = maxCoord > 2f
            Log.i(TAG, "Coordinate space detected: ${if (coordsArePixels == true) "pixels" else "normalized 0-1"} (max sampled center=$maxCoord)")
        }
        val coordScale = if (coordsArePixels == true) 1f else inputWidth.toFloat()

        val scale = letterbox.scale
        val padX = letterbox.padX
        val padY = letterbox.padY
        val srcW = letterbox.srcWidth.toFloat()
        val srcH = letterbox.srcHeight.toFloat()
        val side = inputWidth.toFloat()

        val candidates = ArrayList<Detection>(64)

        for (a in 0 until numAnchors) {
            if (candidates.size > MAX_RAW_DETECTIONS) break

            val bestScore = bestScores[a]
            if (bestScore <= threshold) continue

            val xc = coord(0, a) * coordScale
            val yc = coord(1, a) * coordScale

            // Ignore anchors centered in the letterbox padding (matches iOS)
            if (xc < padX || xc > side - padX || yc < padY || yc > side - padY) continue

            val bestClass = bestClasses[a]
            val w = coord(2, a) * coordScale
            val h = coord(3, a) * coordScale

            // Undo letterbox -> original frame pixels -> normalize
            val origCx = (xc - padX) / scale
            val origCy = (yc - padY) / scale
            val origW = w / scale
            val origH = h / scale

            var nx = (origCx - origW / 2f) / srcW
            var ny = (origCy - origH / 2f) / srcH
            var nw = origW / srcW
            var nh = origH / srcH

            if (nw <= 0.005f || nh <= 0.005f) continue

            nx = nx.coerceIn(0f, 1f)
            ny = ny.coerceIn(0f, 1f)
            nw = max(0.01f, min(1f - nx, nw))
            nh = max(0.01f, min(1f - ny, nh))

            // Reject near-full-frame boxes (matches iOS)
            if (nw * nh > 0.85f) continue

            candidates.add(
                Detection(
                    trackId = -1L,
                    classIndex = bestClass,
                    className = className(bestClass),
                    score = bestScore,
                    rect = RectF(nx, ny, nx + nw, ny + nh),
                )
            )
        }

        val deduplicated = removeDuplicates(candidates)
        val nmsFiltered = applyNms(deduplicated)
        return nmsFiltered
            .sortedByDescending { it.score }
            .take(MAX_DETECTIONS_PER_FRAME)
    }

    /** Class-agnostic suppression of near-identical boxes (IoU > 0.90). */
    private fun removeDuplicates(detections: List<Detection>): List<Detection> {
        val sorted = detections.sortedByDescending { it.score }
        val keep = ArrayList<Detection>(sorted.size)
        outer@ for (d in sorted) {
            for (k in keep) {
                if (iou(k.rect, d.rect) > DUPLICATE_IOU_THRESHOLD) continue@outer
            }
            keep.add(d)
        }
        return keep
    }

    /** Per-class NMS at IoU 0.45. */
    private fun applyNms(detections: List<Detection>): List<Detection> {
        val sorted = detections.sortedByDescending { it.score }
        val keep = ArrayList<Detection>(sorted.size)
        outer@ for (d in sorted) {
            for (k in keep) {
                if (k.className == d.className && iou(k.rect, d.rect) > IOU_THRESHOLD) {
                    continue@outer
                }
            }
            keep.add(d)
        }
        return keep
    }

    private fun iou(r1: RectF, r2: RectF): Float {
        val left = max(r1.left, r2.left)
        val top = max(r1.top, r2.top)
        val right = min(r1.right, r2.right)
        val bottom = min(r1.bottom, r2.bottom)
        if (right <= left || bottom <= top) return 0f
        val inter = (right - left) * (bottom - top)
        val union = r1.width() * r1.height() + r2.width() * r2.height() - inter
        return if (union <= 0f) 0f else inter / union
    }

    fun close() {
        interpreter.close()
        gpuDelegate?.close()
    }
}
