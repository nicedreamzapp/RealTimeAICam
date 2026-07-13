import Foundation
import CoreGraphics

/// Smooths bounding boxes and maintains stable object IDs across frames
final class ObjectTracker {
    static let shared = ObjectTracker()

    // MARK: - Configuration

    /// How much to smooth positions (0 = no smoothing, 1 = infinite smoothing)
    /// Higher values = smoother but slower to respond
    private let positionSmoothingFactor: CGFloat = 0.6

    /// How many frames to keep showing a box after detection is lost
    private let persistenceFrames: Int = 8

    /// IOU threshold to match a new detection with an existing tracked object
    private let matchingIoUThreshold: CGFloat = 0.3

    /// Minimum confidence to start tracking a new object
    private let minConfidenceToTrack: Float = 0.15

    // MARK: - State

    private var trackedObjects: [UUID: TrackedObject] = [:]
    private var frameCount: Int = 0
    private let lock = NSLock()

    private init() {}

    // MARK: - Tracked Object

    private struct TrackedObject {
        let id: UUID
        var className: String
        var classIndex: Int
        var currentRect: CGRect      // Smoothed position
        var targetRect: CGRect       // Latest detection position
        var confidence: Float
        var lastSeenFrame: Int
        var consecutiveHits: Int     // How many frames in a row we've seen this
        var isVisible: Bool          // Whether to show this object
    }

    // MARK: - Public API

    /// Process new detections and return smoothed, stable detections
    func update(with detections: [YOLODetection]) -> [YOLODetection] {
        lock.lock()
        defer { lock.unlock() }

        frameCount += 1

        // Match new detections to existing tracked objects
        var unmatchedDetections = detections
        var matchedTrackIds = Set<UUID>()

        // First pass: match detections to existing tracks by IOU
        for detection in detections {
            if let matchedId = findBestMatch(for: detection) {
                // Update existing track
                var track = trackedObjects[matchedId]!
                track.targetRect = detection.rect
                track.confidence = max(track.confidence * 0.7 + detection.score * 0.3, detection.score)
                track.lastSeenFrame = frameCount
                track.consecutiveHits += 1
                track.isVisible = true
                track.className = detection.className
                track.classIndex = detection.classIndex
                trackedObjects[matchedId] = track

                matchedTrackIds.insert(matchedId)
                unmatchedDetections.removeAll { $0.rect == detection.rect }
            }
        }

        // Second pass: create new tracks for unmatched detections
        for detection in unmatchedDetections {
            guard detection.score >= minConfidenceToTrack else { continue }

            let newTrack = TrackedObject(
                id: UUID(),
                className: detection.className,
                classIndex: detection.classIndex,
                currentRect: detection.rect,
                targetRect: detection.rect,
                confidence: detection.score,
                lastSeenFrame: frameCount,
                consecutiveHits: 1,
                isVisible: true
            )
            trackedObjects[newTrack.id] = newTrack
        }

        // Third pass: update unmatched existing tracks (persistence)
        for (id, var track) in trackedObjects {
            if !matchedTrackIds.contains(id) {
                let framesSinceLastSeen = frameCount - track.lastSeenFrame

                if framesSinceLastSeen > persistenceFrames {
                    // Object has been gone too long, remove it
                    trackedObjects.removeValue(forKey: id)
                } else {
                    // Keep showing but fade confidence
                    track.confidence *= 0.85
                    track.consecutiveHits = 0
                    // Keep visible during persistence window
                    track.isVisible = framesSinceLastSeen <= persistenceFrames
                    trackedObjects[id] = track
                }
            }
        }

        // Fourth pass: smooth positions for all tracks
        for (id, var track) in trackedObjects {
            track.currentRect = smoothRect(
                current: track.currentRect,
                target: track.targetRect,
                factor: positionSmoothingFactor
            )
            trackedObjects[id] = track
        }

        // Return visible tracked objects as YOLODetections with stable IDs
        return trackedObjects.values
            .filter { $0.isVisible && $0.confidence > 0.1 }
            .map { track in
                YOLODetection(
                    id: track.id,  // Use stable tracked ID
                    classIndex: track.classIndex,
                    className: track.className,
                    score: track.confidence,
                    rect: track.currentRect
                )
            }
            .sorted { $0.score > $1.score }
    }

    /// Reset all tracking state
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        trackedObjects.removeAll()
        frameCount = 0
    }

    // MARK: - Private Helpers

    private func findBestMatch(for detection: YOLODetection) -> UUID? {
        var bestMatch: UUID?
        var bestIoU: CGFloat = matchingIoUThreshold

        for (id, track) in trackedObjects {
            // Must be same class
            guard track.className == detection.className else { continue }

            let iou = calculateIoU(rect1: track.currentRect, rect2: detection.rect)
            if iou > bestIoU {
                bestIoU = iou
                bestMatch = id
            }
        }

        return bestMatch
    }

    private func calculateIoU(rect1: CGRect, rect2: CGRect) -> CGFloat {
        let intersection = rect1.intersection(rect2)
        guard !intersection.isNull else { return 0 }

        let intersectionArea = intersection.width * intersection.height
        let unionArea = rect1.width * rect1.height + rect2.width * rect2.height - intersectionArea

        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }

    private func smoothRect(current: CGRect, target: CGRect, factor: CGFloat) -> CGRect {
        // Exponential moving average for smooth transitions
        let smoothedX = current.origin.x * factor + target.origin.x * (1 - factor)
        let smoothedY = current.origin.y * factor + target.origin.y * (1 - factor)
        let smoothedW = current.width * factor + target.width * (1 - factor)
        let smoothedH = current.height * factor + target.height * (1 - factor)

        return CGRect(x: smoothedX, y: smoothedY, width: smoothedW, height: smoothedH)
    }
}
