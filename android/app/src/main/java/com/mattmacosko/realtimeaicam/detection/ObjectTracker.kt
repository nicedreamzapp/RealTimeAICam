package com.mattmacosko.realtimeaicam.detection

import android.graphics.RectF
import kotlin.math.max
import kotlin.math.min

/**
 * Port of the iOS ObjectTracker (project 601): smooths bounding boxes and
 * maintains stable track IDs across frames so boxes don't flicker.
 */
class ObjectTracker {

    // Same tuning as iOS
    private val positionSmoothingFactor = 0.6f     // 0 = none, 1 = frozen
    private val persistenceFrames = 8              // keep boxes after loss
    private val matchingIouThreshold = 0.3f        // match detection -> track
    private val minConfidenceToTrack = 0.15f       // min score to open a track

    private data class TrackedObject(
        val id: Long,
        var className: String,
        var classIndex: Int,
        var currentRect: RectF,   // smoothed
        var targetRect: RectF,    // latest raw detection
        var confidence: Float,
        var lastSeenFrame: Int,
        var consecutiveHits: Int,
        var isVisible: Boolean,
    )

    private val tracks = LinkedHashMap<Long, TrackedObject>()
    private var frameCount = 0
    private var nextId = 1L

    /** Consumes raw detections, returns smoothed detections with stable IDs. */
    @Synchronized
    fun update(detections: List<Detection>): List<Detection> {
        frameCount++

        val matchedTrackIds = HashSet<Long>()
        val unmatched = ArrayList<Detection>()

        // First pass: match detections to existing tracks by IoU (same class)
        for (detection in detections) {
            val matchedId = findBestMatch(detection, matchedTrackIds)
            if (matchedId != null) {
                val track = tracks.getValue(matchedId)
                track.targetRect = RectF(detection.rect)
                track.confidence =
                    max(track.confidence * 0.7f + detection.score * 0.3f, detection.score)
                track.lastSeenFrame = frameCount
                track.consecutiveHits++
                track.isVisible = true
                track.className = detection.className
                track.classIndex = detection.classIndex
                matchedTrackIds.add(matchedId)
            } else {
                unmatched.add(detection)
            }
        }

        // Second pass: open new tracks for unmatched detections
        for (detection in unmatched) {
            if (detection.score < minConfidenceToTrack) continue
            val id = nextId++
            tracks[id] = TrackedObject(
                id = id,
                className = detection.className,
                classIndex = detection.classIndex,
                currentRect = RectF(detection.rect),
                targetRect = RectF(detection.rect),
                confidence = detection.score,
                lastSeenFrame = frameCount,
                consecutiveHits = 1,
                isVisible = true,
            )
        }

        // Third pass: age out or fade unmatched tracks (persistence)
        val iterator = tracks.entries.iterator()
        while (iterator.hasNext()) {
            val (id, track) = iterator.next()
            if (id in matchedTrackIds) continue
            val framesSinceLastSeen = frameCount - track.lastSeenFrame
            if (framesSinceLastSeen > persistenceFrames) {
                iterator.remove()
            } else {
                track.confidence *= 0.85f
                track.consecutiveHits = 0
                track.isVisible = framesSinceLastSeen <= persistenceFrames
            }
        }

        // Fourth pass: exponential smoothing toward the latest detection
        for (track in tracks.values) {
            track.currentRect = smoothRect(track.currentRect, track.targetRect)
        }

        return tracks.values
            .filter { it.isVisible && it.confidence > 0.1f }
            .map {
                Detection(
                    trackId = it.id,
                    classIndex = it.classIndex,
                    className = it.className,
                    score = it.confidence,
                    rect = RectF(it.currentRect),
                )
            }
            .sortedByDescending { it.score }
    }

    @Synchronized
    fun reset() {
        tracks.clear()
        frameCount = 0
    }

    private fun findBestMatch(detection: Detection, alreadyMatched: Set<Long>): Long? {
        var bestMatch: Long? = null
        var bestIou = matchingIouThreshold
        for ((id, track) in tracks) {
            if (id in alreadyMatched) continue
            if (track.className != detection.className) continue
            val iou = iou(track.currentRect, detection.rect)
            if (iou > bestIou) {
                bestIou = iou
                bestMatch = id
            }
        }
        return bestMatch
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

    private fun smoothRect(current: RectF, target: RectF): RectF {
        val f = positionSmoothingFactor
        val g = 1f - f
        return RectF(
            current.left * f + target.left * g,
            current.top * f + target.top * g,
            current.right * f + target.right * g,
            current.bottom * f + target.bottom * g,
        )
    }
}
