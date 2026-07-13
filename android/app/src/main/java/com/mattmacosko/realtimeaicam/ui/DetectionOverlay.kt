package com.mattmacosko.realtimeaicam.ui

import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mattmacosko.realtimeaicam.detection.Detection
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Compose port of the iOS DetectionOverlayView: per-track vibrant colors,
 * translucent rounded boxes, capsule label chips ("class 85%").
 *
 * Detection rects are normalized to the upright analysis frame
 * ([frameWidth] x [frameHeight]); the preview uses FILL_CENTER, so the frame is
 * scaled by max(viewW/frameW, viewH/frameH) and center-cropped. The same
 * transform is applied here so boxes sit on top of what the preview shows.
 */
@Composable
fun DetectionOverlay(
    detections: List<Detection>,
    frameWidth: Int,
    frameHeight: Int,
    modifier: Modifier = Modifier,
) {
    val textPaint = remember {
        android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.WHITE
            typeface = Typeface.create(Typeface.DEFAULT_BOLD, Typeface.BOLD)
            textAlign = android.graphics.Paint.Align.CENTER
            setShadowLayer(3f, 1f, 1f, android.graphics.Color.argb(90, 0, 0, 0))
        }
    }
    val chipPaint = remember { android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG) }

    Canvas(modifier = modifier.fillMaxSize()) {
        if (frameWidth <= 0 || frameHeight <= 0 || detections.isEmpty()) return@Canvas

        // FILL_CENTER mapping: frame -> view
        val viewW = size.width
        val viewH = size.height
        val scale = max(viewW / frameWidth, viewH / frameHeight)
        val offsetX = (viewW - frameWidth * scale) / 2f
        val offsetY = (viewH - frameHeight * scale) / 2f

        val cornerRadius = 12.dp.toPx()
        val strokeWidth = 2.dp.toPx()
        val chipHeight = 24.dp.toPx()
        val chipPadH = 8.dp.toPx()
        textPaint.textSize = 14.sp.toPx()

        val occupiedChips = ArrayList<Rect>()

        for (detection in detections.sortedByDescending { it.score }) {
            val color = trackColor(detection.trackId)

            val left = detection.rect.left * frameWidth * scale + offsetX
            val top = detection.rect.top * frameHeight * scale + offsetY
            val boxW = detection.rect.width() * frameWidth * scale
            val boxH = detection.rect.height() * frameHeight * scale

            // Bounding box: soft fill + stroke (matches iOS 0.15 / 0.5 opacities)
            drawRoundRect(
                color = color.copy(alpha = 0.15f),
                topLeft = Offset(left, top),
                size = Size(boxW, boxH),
                cornerRadius = CornerRadius(cornerRadius, cornerRadius),
            )
            drawRoundRect(
                color = color.copy(alpha = 0.5f),
                topLeft = Offset(left, top),
                size = Size(boxW, boxH),
                cornerRadius = CornerRadius(cornerRadius, cornerRadius),
                style = Stroke(width = strokeWidth),
            )

            // Label chip: "class 85%"
            val label = "${detection.className.lowercase()} ${(detection.score * 100).roundToInt()}%"
            val textWidth = textPaint.measureText(label)
            val chipWidth = textWidth + chipPadH * 2

            // Prefer above the box; fall back below, then inside-top.
            val cx = (left + boxW / 2f)
                .coerceIn(chipWidth / 2f, max(chipWidth / 2f, viewW - chipWidth / 2f))
            val candidatesY = listOf(
                top - chipHeight * 0.75f,
                top + boxH + chipHeight * 0.75f,
                top + chipHeight,
            )
            var cy = candidatesY.first().coerceIn(chipHeight / 2f, max(chipHeight / 2f, viewH - chipHeight / 2f))
            for (candidate in candidatesY) {
                val y = candidate.coerceIn(chipHeight / 2f, max(chipHeight / 2f, viewH - chipHeight / 2f))
                val rect = Rect(
                    cx - chipWidth / 2f, y - chipHeight / 2f,
                    cx + chipWidth / 2f, y + chipHeight / 2f,
                )
                if (occupiedChips.none { it.overlaps(rect) }) {
                    cy = y
                    occupiedChips.add(rect)
                    break
                }
            }

            val chipLeft = cx - chipWidth / 2f
            val chipTop = cy - chipHeight / 2f
            chipPaint.color = color.copy(alpha = 0.35f).toArgb()

            drawContext.canvas.nativeCanvas.apply {
                drawRoundRect(
                    chipLeft, chipTop, chipLeft + chipWidth, chipTop + chipHeight,
                    chipHeight / 2f, chipHeight / 2f, chipPaint,
                )
                val textY = cy - (textPaint.descent() + textPaint.ascent()) / 2f
                drawText(label, cx, textY, textPaint)
            }
        }
    }
}

// Same 10 vibrant colors as the iOS DetectionOverlayView, keyed to the stable
// track ID so an object keeps its color for as long as it is tracked.
private val vibrantColors = listOf(
    Color(1.00f, 0.20f, 0.40f), // Hot Pink
    Color(0.00f, 0.90f, 1.00f), // Cyan
    Color(0.50f, 1.00f, 0.00f), // Lime Green
    Color(1.00f, 0.50f, 0.00f), // Orange
    Color(0.80f, 0.00f, 1.00f), // Purple
    Color(1.00f, 1.00f, 0.00f), // Yellow
    Color(0.00f, 0.50f, 1.00f), // Sky Blue
    Color(1.00f, 0.00f, 0.50f), // Magenta
    Color(0.00f, 1.00f, 0.50f), // Spring Green
    Color(1.00f, 0.70f, 0.00f), // Gold
)

private fun trackColor(trackId: Long): Color {
    // djb2-style hash, like the iOS objectColor(_:)
    var hash = 5381L
    for (b in trackId.toString().encodeToByteArray()) {
        hash = hash * 33 + (b.toLong() and 0xFF)
    }
    val index = ((hash % vibrantColors.size) + vibrantColors.size) % vibrantColors.size
    return vibrantColors[index.toInt()]
}
