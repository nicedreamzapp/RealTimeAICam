import AVFoundation
import Combine
import Foundation
import UIKit

// MARK: - App Mode Definition

enum AppMode: String, CaseIterable {
    case home
    case objectDetection
    case ocrEnglish
    case ocrSpanish

    var displayName: String {
        switch self {
        case .home: "Home"
        case .objectDetection: "Object Detection"
        case .ocrEnglish: "English OCR"
        case .ocrSpanish: "Spanish OCR"
        }
    }
}

// MARK: - Resource Manager - The Central Brain

@MainActor
final class ResourceManager: ObservableObject {
    // MARK: - Singleton

    static let shared = ResourceManager()

    // MARK: - Published State

    @Published private(set) var currentMode: AppMode = .home
    @Published private(set) var isTransitioning: Bool = false
    @Published private(set) var memoryUsage: Double = 0.0
    @Published private(set) var backgroundProcessCount: Int = 0

    // MARK: - Engine References (All start as NIL)

    private var yoloEngine: YOLOv8Processor?
    private var ocrEngine: Any? // Will be LiveOCRViewModel when needed
    private var lidarEngine: LiDARManager?
    private var cameraEngine: CameraViewModel?
    private var speechEngine: SpeechManager?

    // MARK: - Resource State Tracking

    private var activeResources: Set<String> = []
    private var lastMemoryCheck = Date()

    // MARK: - Private Init (Singleton)

    private init() {
        setupMemoryMonitoring()
    }

    // MARK: - Main Mode Switching API

    func switchToMode(_ newMode: AppMode) {
        guard currentMode != newMode else { return }

        isTransitioning = true

        // Directly load new mode resources without teardown
        loadMode(newMode)
        currentMode = newMode
        isTransitioning = false
    }

    // MARK: - Mode Loading (Only Load What's Needed)

    private func loadMode(_ mode: AppMode) {
        switch mode {
        case .home:
            loadHomeMode()

        case .objectDetection:
            loadObjectDetectionMode()

        case .ocrEnglish:
            loadOCRMode(language: .english)

        case .ocrSpanish:
            loadOCRMode(language: .spanish)
        }

        updateResourceCount()
    }

    // MARK: - Individual Mode Loaders

    private func loadHomeMode() {
        // HOME = ZERO BACKGROUND PROCESSES
        activeResources.removeAll()
    }

    private func loadObjectDetectionMode() {
        // Load YOLO (on-demand)
        loadYOLOEngine()

        // LiDAR only if supported and user enables it
        if LiDARManager.shared.isSupported {
            lidarEngine = LiDARManager.shared
            activeResources.insert("LiDAR")
        }

        // Speech for announcements
        loadSpeechEngine()

        activeResources.insert("YOLO")
        activeResources.insert("Camera")
    }

    private func loadOCRMode(language _: OCRLanguage) {
        // OCR Engine (create new instance)
        ocrEngine = LiveOCRViewModel()
        activeResources.insert("OCR")

        // Speech for reading text
        loadSpeechEngine()

        activeResources.insert("Camera")
    }

    // MARK: - Engine Loaders (Lazy Creation)

    private func loadYOLOEngine() {
        guard yoloEngine == nil else { return }

        let tier = DevicePerf.shared.tier
        let side = switch tier {
        case .low: 352
        case .mid: 512
        case .high: 640
        }

        do {
            yoloEngine = try YOLOv8Processor(targetSide: side)
        } catch {
            // no print
        }
    }

    private func loadSpeechEngine() {
        guard speechEngine == nil else { return }

        speechEngine = SpeechManager()
        activeResources.insert("Speech")
    }

    // MARK: - Complete Teardown

    private func teardownCurrentMode() {
        // Destroy all engines
        unloadYOLOEngine()
        unloadOCREngine()
        unloadLiDAREngine()
        unloadSpeechEngine()

        // Clear active resources
        activeResources.removeAll()

        // Force memory cleanup
        autoreleasepool {
            // This helps release retained objects
        }
    }

    // MARK: - Engine Unloaders (Complete Destruction)

    private func unloadYOLOEngine() {
        if yoloEngine != nil {
            yoloEngine = nil
            activeResources.remove("YOLO")
        }
    }

    private func unloadOCREngine() {
        if ocrEngine != nil {
            (ocrEngine as? LiveOCRViewModel)?.shutdown()
            ocrEngine = nil
            activeResources.remove("OCR")
        }
    }

    private func unloadLiDAREngine() {
        if lidarEngine != nil {
            lidarEngine?.stop()
            lidarEngine = nil
            activeResources.remove("LiDAR")
        }
    }

    private func unloadSpeechEngine() {
        if speechEngine != nil {
            speechEngine?.stopSpeech()
            speechEngine = nil
            activeResources.remove("Speech")
        }
    }

    // MARK: - Resource Access (For Integration)

    func getYOLOEngine() -> YOLOv8Processor? {
        yoloEngine
    }

    func getOCREngine() -> LiveOCRViewModel? {
        ocrEngine as? LiveOCRViewModel
    }

    func getLiDAREngine() -> LiDARManager? {
        lidarEngine
    }

    func getSpeechEngine() -> SpeechManager? {
        speechEngine
    }

    // MARK: - Memory Monitoring

    private func setupMemoryMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateMemoryUsage()
            }
        }
    }

    private func updateMemoryUsage() {
        memoryUsage = Double(MemoryManager.currentMemoryUsageMB())
        updateResourceCount()

        // Log every 10 seconds - but logResourceState removed, so nothing here
        let now = Date()
        if now.timeIntervalSince(lastMemoryCheck) > 10.0 {
            lastMemoryCheck = now
        }
    }

    private func updateResourceCount() {
        backgroundProcessCount = activeResources.count
    }

    // MARK: - Emergency Cleanup

    func emergencyCleanup() {
        teardownCurrentMode()
        currentMode = .home
        loadMode(.home)
    }

    // MARK: - Resource Verification

    func verifyCleanState() -> Bool {
        let hasYOLO = (yoloEngine != nil)
        let hasOCR = (ocrEngine != nil)
        let hasLiDAR = (lidarEngine != nil)
        let hasSpeech = (speechEngine != nil)

        let shouldBeClean = (currentMode == .home)

        if shouldBeClean {
            let isClean = !hasYOLO && !hasOCR && !hasLiDAR && !hasSpeech
            if !isClean {
                // no print
            }
            return isClean
        }

        return true
    }
}

// MARK: - OCR Language Enum

enum OCRLanguage {
    case english
    case spanish

    var displayName: String {
        switch self {
        case .english: "English"
        case .spanish: "Spanish"
        }
    }
}
