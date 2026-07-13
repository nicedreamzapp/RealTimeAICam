package com.mattmacosko.realtimeaicam.camera

import com.mattmacosko.realtimeaicam.detection.Detection

/** Everything the UI needs to render one frame's worth of results. */
data class DetectionUiState(
    val detections: List<Detection> = emptyList(),
    val fps: Float = 0f,
    val inferenceMs: Long = 0,
    /** Upright (rotation-corrected) analysis frame size; detection rects are normalized to this. */
    val frameWidth: Int = 0,
    val frameHeight: Int = 0,
    /** Non-null when the model could not be loaded (e.g. asset missing). */
    val modelError: String? = null,
    /** Raw interpreter output shape, for the debug readout. */
    val outputShape: String = "",
)
