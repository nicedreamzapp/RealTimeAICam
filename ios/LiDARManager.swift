// LiDARManager.swift - RESTORED WORKING VERSION
import AVFoundation
import Combine
import CoreVideo
import Foundation
import UIKit

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

/// LiDAR state manager with actual depth processing
final class LiDARManager: NSObject, ObservableObject {
    // MARK: - Singleton

    static let shared = LiDARManager()

    // MARK: - Public state

    @Published private(set) var isSupported: Bool = false
    @Published private(set) var isRunning: Bool = false
    @Published var isEnabled: Bool = false
    @Published private(set) var isAvailable: Bool = false

    var isActive: Bool {
        isEnabled && isAvailable
    }

    // MARK: - Private

    // Written on the camera depth-delegate queue, read on main — lock required.
    private let depthLock = NSLock()
    private var _latestDepthData: AVDepthData?
    private var latestDepthData: AVDepthData? {
        get { depthLock.lock(); defer { depthLock.unlock() }; return _latestDepthData }
        set { depthLock.lock(); _latestDepthData = newValue; depthLock.unlock() }
    }
    private let processingQueue = DispatchQueue(label: "lidar.processing", qos: .userInitiated)
    private var depthHistory: [UUID: [Double]] = [:]
    private let maxHistorySize = 7

    // MARK: - Init

    override private init() {
        super.init()

        // Force immediate support check
        checkSupport()

        NotificationCenter.default.addObserver(self, selector: #selector(handleReduceQualityForMemory), name: .reduceQualityForMemory, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleReduceFrameRate), name: .reduceFrameRate, object: nil)
    }

    @objc private func handleReduceQualityForMemory() {
        DispatchQueue.main.async { [weak self] in
            self?.latestDepthData = nil
            self?.depthHistory.removeAll()
        }
    }

    @objc private func handleReduceFrameRate() {}

    private func checkSupport() {
        // Only the dedicated LiDAR camera counts (iPhone 12 Pro and later Pro
        // models). The camera pipeline attaches depth exclusively from
        // builtInLiDARDepthCamera, so advertising the ruler button on dual/triple
        // camera non-Pro phones showed a toggle that could never produce a distance.
        let supported = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil
        DispatchQueue.main.async {
            self.isSupported = supported
        }
    }

    // MARK: - Control

    func setEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isEnabled = enabled
            self?.isRunning = enabled
        }
    }

    /// Manual support check - call this if button doesn't appear
    func recheckSupport() {
        checkSupport()
    }

    func toggle() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let newState = !isEnabled
            isEnabled = newState
            isRunning = newState

            if !newState {
                latestDepthData = nil
            }
        }
    }

    func setAvailable(_ available: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isAvailable = available
            if !available, self?.isEnabled == true {
                self?.isRunning = false
            } else if available, self?.isEnabled == true {
                self?.isRunning = true
            }
        }
    }

    func start() {
        DispatchQueue.main.async { [weak self] in
            self?.isEnabled = true
            self?.isRunning = true
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.isEnabled = false
            self?.isRunning = false
            self?.latestDepthData = nil
        }
    }

    // MARK: - Depth Data Update (called by CameraViewModel)

    func updateDepthData(_ depthData: AVDepthData) {
        guard isEnabled else {
            // print("LiDAR: Depth data received but LiDAR is disabled")
            return
        }
        latestDepthData = depthData
        // Suppressed frequent per-frame depth data size print to avoid console spamming
        // print("LiDAR: Depth data updated - size: \(width)x\(height)")
    }

    // MARK: - Public API

    /// Diagnostic version: Sample a 5x5 grid and use median depth
    func distanceInMeters(atNormalizedPoint pt: CGPoint) -> Double? {
        guard isEnabled, let depthData = latestDepthData else {
            // print("LiDAR: No depth data available")
            return nil
        }

        var allDepths: [Double] = []

        for yOffset in stride(from: -0.04, through: 0.04, by: 0.02) {
            for xOffset in stride(from: -0.04, through: 0.04, by: 0.02) {
                let samplePoint = CGPoint(
                    x: max(0, min(1, pt.x + xOffset)),
                    y: max(0, min(1, pt.y + yOffset))
                )
                if let depth = sampleSinglePoint(samplePoint, from: depthData) {
                    if depth > 0.3, depth < 10.0, depth.isFinite {
                        allDepths.append(depth)
                    }
                }
            }
        }

        guard !allDepths.isEmpty else {
            // print("LiDAR: No valid samples found")
            return nil
        }

        allDepths.sort()
        let medianDepth = allDepths[allDepths.count / 2]

        // Suppressed per-call detailed depth sample print to reduce console spam
        // print("LiDAR: Sampled \(allDepths.count) points, depths range from \(allDepths.first!)m to \(allDepths.last!)m, using median: \(medianDepth)m = \(Int(medianDepth * 3.28))ft")

        return medianDepth
    }

    // MARK: - Multi-point sampling helper (pixel buffer read)

    private func sampleSinglePoint(_ pt: CGPoint, from depthData: AVDepthData) -> Double? {
        let depthMap = depthData.depthDataMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return nil }
        let x = Int((pt.x * CGFloat(width)).rounded(.toNearestOrAwayFromZero))
        let y = Int((pt.y * CGFloat(height)).rounded(.toNearestOrAwayFromZero))
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let pixelFormat = CVPixelBufferGetPixelFormatType(depthMap)
        var depthValue: Float = 0

        switch pixelFormat {
        case kCVPixelFormatType_DisparityFloat32:
            let rowData = baseAddress + y * CVPixelBufferGetBytesPerRow(depthMap)
            let depthPointer = rowData.assumingMemoryBound(to: Float32.self)
            let disparity = depthPointer[x]
            depthValue = 1.0 / disparity

        case kCVPixelFormatType_DepthFloat32:
            let rowData = baseAddress + y * CVPixelBufferGetBytesPerRow(depthMap)
            let depthPointer = rowData.assumingMemoryBound(to: Float32.self)
            depthValue = depthPointer[x]

        case kCVPixelFormatType_DisparityFloat16:
            let rowData = baseAddress + y * CVPixelBufferGetBytesPerRow(depthMap)
            let depthPointer = rowData.assumingMemoryBound(to: Float16.self)
            let disparity = Float(depthPointer[x])
            depthValue = 1.0 / disparity

        case kCVPixelFormatType_DepthFloat16:
            let rowData = baseAddress + y * CVPixelBufferGetBytesPerRow(depthMap)
            let depthPointer = rowData.assumingMemoryBound(to: Float16.self)
            depthValue = Float(depthPointer[x])

        default:
            return nil
        }

        guard depthValue > 0, depthValue.isFinite else {
            // print("LiDAR: Invalid depth value: \(depthValue)")
            return nil
        }
        return Double(depthValue)
    }

    /// Returns temporally smoothed distance (meters) for detection ID at point
    func smoothedDistanceInMeters(for detectionId: UUID, at normalizedPoint: CGPoint) -> Double? {
        guard let newDepth = distanceInMeters(atNormalizedPoint: normalizedPoint) else { return nil }
        var history = depthHistory[detectionId] ?? []
        history.append(newDepth)
        if history.count > maxHistorySize {
            history.removeFirst(history.count - maxHistorySize)
        }
        depthHistory[detectionId] = history
        let n = Double(history.count)
        let mean = history.reduce(0, +) / n
        let variance = history.reduce(0) { $0 + pow($1 - mean, 2) } / n
        let stddev = sqrt(variance)
        // Suppressed frequent history print to reduce console spam
        // print("LiDAR: ID \(detectionId) depth history = \(history), mean = \(mean), stddev = \(stddev)")
        if stddev < 0.15 {
            return mean
        } else {
            return newDepth
        }
    }

    /// Returns smoothed distance in feet for detection ID
    func smoothedDistanceFeet(for detectionId: UUID, at normalizedPoint: CGPoint) -> Int? {
        guard let meters = smoothedDistanceInMeters(for: detectionId, at: normalizedPoint) else { return nil }
        return LiDARManager.roundedFeet(fromMeters: meters)
    }

    /// Cleans up history for detections no longer present
    func cleanupOldHistories(currentDetectionIds: Set<UUID>) {
        depthHistory.keys.filter { !currentDetectionIds.contains($0) }.forEach { depthHistory.removeValue(forKey: $0) }
    }

    /// Convenience method to get distance in feet
    func distanceFeet(at normalizedPoint: CGPoint) -> Int? {
        guard let meters = distanceInMeters(atNormalizedPoint: normalizedPoint) else {
            return nil
        }
        let feet = LiDARManager.roundedFeet(fromMeters: meters)
        // Suppressed frequent print
        // print("LiDAR: Distance = \(feet) feet")
        return feet
    }

    /// Batch variant
    func distancesInMeters<ID: Hashable>(for points: [(id: ID, point: CGPoint)]) -> [ID: Double] {
        var results: [ID: Double] = [:]
        for (id, point) in points {
            if let meters = distanceInMeters(atNormalizedPoint: point) {
                results[id] = meters
            }
        }
        return results
    }

    /// Convenience: rounds meters to nearest foot
    static func roundedFeet(fromMeters meters: Double) -> Int {
        let feet = meters * 3.280839895
        return Int((feet + 0.5).rounded(.down))
    }

    /// Convenience: left/center/right label from normalized X
    static func horizontalBucket(forNormalizedX x: CGFloat) -> String {
        if x < 0.33 { return "L" }
        if x > 0.66 { return "R" }
        return "C"
    }
}

// MARK: - LiDARDepthProviding Protocol Conformance

extension LiDARManager: LiDARDepthProviding {
    func depthInMeters(at normalizedPoint: CGPoint) -> Float? {
        guard let meters = distanceInMeters(atNormalizedPoint: normalizedPoint) else { return nil }
        return Float(meters)
    }
}
