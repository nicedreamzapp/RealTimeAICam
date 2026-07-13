package com.mattmacosko.realtimeaicam.detection

import android.graphics.RectF

/**
 * One detected object. [rect] is normalized 0..1 relative to the upright
 * (rotation-corrected) camera frame. [trackId] is stable across frames once
 * the ObjectTracker has matched the detection to a track.
 */
data class Detection(
    val trackId: Long,
    val classIndex: Int,
    val className: String,
    val score: Float,
    val rect: RectF,
)

/** Letterbox transform used when scaling a frame into the model's square input. */
data class LetterboxInfo(
    val scale: Float,
    val padX: Float,
    val padY: Float,
    val srcWidth: Int,
    val srcHeight: Int,
)
