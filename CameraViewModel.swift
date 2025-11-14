@preconcurrency import AVFoundation
import Combine
import Foundation
import SwiftUI
import UIKit

// MARK: - ThermalManager

final class ThermalManager {
    static let shared = ThermalManager()

    private var thermalStateObserver: NSObjectProtocol?

    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    private init() {
        thermalState = ProcessInfo.processInfo.thermalState
        thermalStateObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    deinit {
        if let observer = thermalStateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isThrottlingRecommended: Bool {
        thermalState == .serious || thermalState == .critical
    }
}

final nonisolated class DepthDataDelegate: NSObject, AVCaptureDepthDataOutputDelegate {
    func depthDataOutput(_: AVCaptureDepthDataOutput,
                         didOutput depthData: AVDepthData,
                         timestamp _: CMTime,
                         connection _: AVCaptureConnection)
    {
        // Capture depthData immediately to avoid Sendable issues
        let capturedDepthData = depthData
        DispatchQueue.main.async {
            LiDARManager.shared.updateDepthData(capturedDepthData)
        }
    }
}

// MARK: - LiDAR Protocol

protocol LiDARDepthProviding: AnyObject {
    /// Normalized point in [0,1] x [0,1] image space (same as detection.rect)
    func depthInMeters(at normalizedPoint: CGPoint) -> Float?
    /// True when device supports scene depth
    var isAvailable: Bool { get }
    /// Manager can pause/resume internally based on this toggle
    var isEnabled: Bool { get set }
}

// MARK: - Camera Permission Alert

struct CameraPermissionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let openSettings: () -> Void
}

// MARK: - OCR Delegate Protocol

protocol CameraViewModelOCRDelegate: AnyObject {
    func cameraViewModel(_ viewModel: CameraViewModel, didOutputPixelBuffer pixelBuffer: CVPixelBuffer)
}

// MARK: - Device Orientation Extension

extension UIDeviceOrientation {
    var isPortrait: Bool {
        self == .portrait || self == .portraitUpsideDown || !isValidInterfaceOrientation
    }
}

class CameraViewModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // MARK: - Constants

    private enum Constants {
        static let sessionQueue = "AVCaptureSessionQueue"
        static let videoQueue = "videoQueue"
        static let maxFrameSamples = 15
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Speech Manager

    @StateObject private var speechManager = SpeechManager()

    // MARK: - Published Properties

    @Published var currentOrientation: UIDeviceOrientation = .portrait
    @Published var isUltraWide = false
    @Published var detections: [YOLODetection] = []
    @Published var framesPerSecond: Double = 0
    @Published var filterMode = "all"
    @Published var confidenceThreshold: Float = 0.75
    @Published var frameRate = 30 { didSet { updateFrameProcessingRate() } }
    @Published var currentZoomLevel: CGFloat = 1.0
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    @Published var cameraPermissionAlert: CameraPermissionAlert?

    // Added new published property for LiDAR notifications
    @Published var lidarNotificationMessage: String?

    // LiDAR properties
    @Published var useLiDAR: Bool = false {
        didSet {
            // Synchronize isLiDAREnabled with useLiDAR, but do NOT call LiDARManager here to avoid duplication
            if isLiDAREnabled != useLiDAR {
                isLiDAREnabled = useLiDAR
            }
        }
    }

    @Published var isLiDARSupported: Bool = false
    @Published var isLiDAREnabled: Bool = false
    private var lastDistancesFeet: [UUID: Int] = [:]

    // OCR flag
    @Published var isOCREnabled: Bool = false

    private var savedTorchLevel: Float = 0.0

    @Published var currentTorchLevel: Float = 0.0 {
        didSet {
            // Only call setTorchLevel if we're not in the middle of session reconfiguration
            if isSessionConfigured, session.isRunning {
                setTorchLevel(currentTorchLevel)
            }
        }
    }

    var detectedObjectCount: Int { detections.count }

    // Speech properties (delegated to SpeechManager)
    var isSpeechEnabled: Bool {
        get { SpeechManager.shared.isSpeechEnabled }
        set { SpeechManager.shared.isSpeechEnabled = newValue }
    }

    var selectedVoiceIdentifier: String {
        get { SpeechManager.shared.selectedVoiceIdentifier }
        set { SpeechManager.shared.selectedVoiceIdentifier = newValue }
    }

    var availableEnglishVoices: [AVSpeechSynthesisVoice] {
        speechManager.availableEnglishVoices
    }

    // MARK: - Internal Properties

    weak var ocrDelegate: CameraViewModelOCRDelegate?

    // LiDAR bridge
    weak var lidar: LiDARDepthProviding? {
        didSet {
            isLiDARSupported = lidar?.isAvailable ?? false
            lidar?.isEnabled = useLiDAR
        }
    }

    let session = AVCaptureSession()
    lazy var previewLayer = AVCaptureVideoPreviewLayer(session: session)
    lazy var yoloProcessor: YOLOv8Processor? = {
        let tier = DevicePerf.shared.tier
        let side = switch tier {
        case .low: 352
        case .mid: 512
        case .high: 640
        }
        if let proc = try? YOLOv8Processor(targetSide: side) {
            return proc
        } else {
            let fallback = try? YOLOv8Processor()
            fallback?.configureTargetSide(side)
            return fallback
        }
    }()

    // MARK: - Private Properties

    private var frameCounter = 0
    private var isProcessing = false

    private static let sessionQueue = DispatchQueue(label: Constants.sessionQueue)
    private let videoQueue = DispatchQueue(label: Constants.videoQueue, qos: .userInitiated)

    private var isSessionConfigured = false
    private var currentDevice: AVCaptureDevice?
    private var processEveryNFrames = 1
    private var videoConnection: AVCaptureConnection?

    // FPS tracking
    private var lastFrameTimestamps: [CFTimeInterval] = []

    // Observers
    private var orientationObserver: NSObjectProtocol?
    private var rotationCoordinator: Any?

    // Zoom
    var initialZoomFactor: CGFloat = 1.0
    private var minimumZoomFactor: CGFloat = 1.0
    private var maximumZoomFactor: CGFloat = 5.0

    // Removed LiDAR Camera Manager property

    // Added depth capture properties
    private var depthDataOutput: AVCaptureDepthDataOutput?
    private var depthDelegate: AVCaptureDepthDataOutputDelegate?

    // MARK: - Initialization

    override init() {
        super.init()

        setupThermalManagement()
        enableThermalBreaks()

        lidar = LiDARManager.shared

        setupInitialState()

        // Observe LiDAR state changes
        NotificationCenter.default.addObserver(forName: Notification.Name("LiDARStateChanged"), object: nil, queue: OperationQueue.main) { [weak self] _ in
            self?.isLiDARSupported = LiDARManager.shared.isSupported
            self?.useLiDAR = LiDARManager.shared.isEnabled
        }

        // Force update after brief delay to ensure support check completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.isLiDARSupported = LiDARManager.shared.isSupported
        }

        // Set conservative defaults based on device tier
        switch DevicePerf.shared.tier {
        case .low:
            frameRate = 10
            confidenceThreshold = 0.45
            if session.canSetSessionPreset(.hd1280x720) {
                session.sessionPreset = .hd1280x720
            }
        case .mid:
            frameRate = 15
            confidenceThreshold = 0.42
            if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            }
        case .high:
            frameRate = 20
            confidenceThreshold = 0.39
            if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            }
        }

        // Add MemoryManager observers
        NotificationCenter.default.addObserver(forName: Notification.Name.reduceQualityForMemory, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            clearDetections()
            yoloProcessor?.reset()
        }
        NotificationCenter.default.addObserver(forName: Notification.Name.reduceFrameRate, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            frameRate = 15
            processEveryNFrames = 3
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                self.frameRate = 30
                self.processEveryNFrames = 1
            }
        }
    }

    private func setupInitialState() {
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            self.deviceOrientationDidChange()
        }

        currentOrientation = UIDevice.current.orientation
        if !currentOrientation.isValidInterfaceOrientation {
            currentOrientation = .portrait
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
        }

        updateFrameProcessingRate()

        LiDARManager.shared.$isSupported
            .receive(on: DispatchQueue.main)
            .assign(to: &$isLiDARSupported)
    }

    deinit {
        cleanup()
    }

    private func cleanup() {
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        if #available(iOS 17.0, *) {
            (rotationCoordinator as? AVCaptureDevice.RotationCoordinator)?.removeObserver(self, forKeyPath: "videoRotationAngleForHorizonLevelCapture")
        }

        stopSpeech()
        stopSession()

        DispatchQueue.main.async {
            self.detections = []
        }
    }

    // MARK: - Orientation Handling

    @objc private func deviceOrientationDidChange() {
        let newOrientation = UIDevice.current.orientation

        if newOrientation.isValidInterfaceOrientation, newOrientation != .portraitUpsideDown {
            currentOrientation = newOrientation
        }

        // Preserve torch during orientation changes
        let preservedTorch = currentTorchLevel

        updateVideoRotation()

        // Restore torch if it was on
        if preservedTorch > 0, cameraPosition == .back {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.currentTorchLevel = preservedTorch
            }
        }
    }

    private func updateFrameProcessingRate() {
        processEveryNFrames = 1
    }

    // MARK: - Zoom Control

    func handlePinchGesture(_ scale: CGFloat) {
        guard let device = currentDevice else { return }

        let targetZoom = initialZoomFactor * scale
        let clampedZoom = max(minimumZoomFactor, min(targetZoom, maximumZoomFactor))

        if abs(device.videoZoomFactor - clampedZoom) > 0.01 {
            configureDevice(device) { dev in
                let finalZoom = min(dev.activeFormat.videoMaxZoomFactor, max(1.0, clampedZoom))
                dev.videoZoomFactor = finalZoom

                DispatchQueue.main.async {
                    self.currentZoomLevel = finalZoom
                    if finalZoom <= self.minimumZoomFactor || finalZoom >= self.maximumZoomFactor {
                        self.initialZoomFactor = finalZoom
                    }
                }
            }
        }
    }

    func setPinchGestureStartZoom() {
        if let device = currentDevice {
            initialZoomFactor = device.videoZoomFactor
        } else {
            initialZoomFactor = currentZoomLevel
        }
    }

    // MARK: - Camera Setup

    private func setupCamera() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            return
        }

        session.beginConfiguration()
        if isOCREnabled {
            if session.canSetSessionPreset(.photo) {
                session.sessionPreset = .photo
            } else if session.canSetSessionPreset(.hd4K3840x2160) {
                session.sessionPreset = .hd4K3840x2160
            } else if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            } else {
                configureSessionPreset()
            }
        } else {
            configureSessionPreset()
        }

        guard let device = selectCamera() else {
            session.commitConfiguration()
            return
        }

        currentDevice = device
        configureCamera(device)
        setupRotationCoordinator()
        setupCameraInput(device: device)
    }

    private func configureSessionPreset() {
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
    }

    private func selectCamera() -> AVCaptureDevice? {
        if cameraPosition == .front {
            DispatchQueue.main.async {
                self.isUltraWide = false
                LiDARManager.shared.setAvailable(false)
            }
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        } else {
            if isUltraWide {
                if let ultraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
                    DispatchQueue.main.async {
                        LiDARManager.shared.setAvailable(false)
                    }
                    return ultraWide
                } else {
                    DispatchQueue.main.async { self.isUltraWide = false }
                }
            }

            if !isUltraWide, let lidarCamera = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) {
                DispatchQueue.main.async {
                    LiDARManager.shared.setAvailable(true)
                }
                return lidarCamera
            }

            if let wideCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                let supportsDepth = !wideCamera.activeFormat.supportedDepthDataFormats.isEmpty
                DispatchQueue.main.async {
                    LiDARManager.shared.setAvailable(supportsDepth)
                }
                return wideCamera
            }

            return nil
        }
    }

    private func configureCamera(_ camera: AVCaptureDevice) {
        configureDevice(camera) { device in
            if device.deviceType == .builtInUltraWideCamera {
                self.minimumZoomFactor = device.minAvailableVideoZoomFactor
            } else if device.deviceType == .builtInLiDARDepthCamera {
                self.minimumZoomFactor = 0.5
            } else {
                self.minimumZoomFactor = max(0.5, device.minAvailableVideoZoomFactor)
            }

            let deviceMax = device.maxAvailableVideoZoomFactor
            if device.deviceType == .builtInLiDARDepthCamera {
                self.maximumZoomFactor = min(deviceMax, 10.0)
            } else {
                self.maximumZoomFactor = min(deviceMax * 0.95, 10.0)
            }

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }

            if isOCREnabled {
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    device.exposureMode = .continuousAutoExposure
                }
            }

            if device.deviceType == .builtInUltraWideCamera {
                device.videoZoomFactor = self.minimumZoomFactor
                DispatchQueue.main.async {
                    self.currentZoomLevel = self.minimumZoomFactor
                    self.initialZoomFactor = self.minimumZoomFactor
                }
            } else {
                device.videoZoomFactor = 1.0
                DispatchQueue.main.async {
                    self.currentZoomLevel = 1.0
                    self.initialZoomFactor = 1.0
                }
            }
        }
    }

    private func setupRotationCoordinator() {
        guard let device = currentDevice else { return }

        if #available(iOS 17.0, *) {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            coordinator.addObserver(self, forKeyPath: "videoRotationAngleForHorizonLevelCapture", options: [.new], context: nil)
            rotationCoordinator = coordinator
            updateVideoRotation()
        } else {
            if let connection = previewLayer.connection {
                connection.videoOrientation = .portrait
            }
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if #available(iOS 17.0, *) {
            if keyPath == "videoRotationAngleForHorizonLevelCapture" {
                updateVideoRotation()
            } else {
                super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    private func updateVideoRotation() {
        if #available(iOS 17.0, *) {
            guard let coordinator = rotationCoordinator as? AVCaptureDevice.RotationCoordinator,
                  let connection = videoConnection else { return }

            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }

            previewLayer.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        } else {
            if let connection = videoConnection {
                if connection.isVideoOrientationSupported {
                    switch currentOrientation {
                    case .landscapeLeft:
                        connection.videoOrientation = .landscapeRight
                    case .landscapeRight:
                        connection.videoOrientation = .landscapeLeft
                    default:
                        connection.videoOrientation = .portrait
                    }
                }
            }
        }
    }

    private func setupCameraInput(device: AVCaptureDevice) {
        do {
            let input = try AVCaptureDeviceInput(device: device)

            session.inputs.forEach { session.removeInput($0) }

            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                session.commitConfiguration()
                return
            }
        } catch {
            session.commitConfiguration()
            return
        }

        setupVideoOutput()
    }

    private func setupVideoOutput() {
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: videoQueue)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true

        session.outputs.forEach { session.removeOutput($0) }

        if session.canAddOutput(output) {
            session.addOutput(output)

            if let connection = output.connection(with: .video) {
                videoConnection = connection
                updateVideoRotation()
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = (cameraPosition == .front)
                }
            }
        }

        session.commitConfiguration()
        isSessionConfigured = true
    }

    // MARK: - Session Control

    func startSession() {
        guard !session.isRunning else {
            return
        }
        checkAndHandleCameraPermission()
        Self.sessionQueue.async { [weak self] in
            guard let self else { return }
            if isSessionConfigured {
                if !session.isRunning {
                    session.startRunning()
                    DispatchQueue.main.async { self.updateVideoRotation() }
                }
            } else {
                setupCamera()

                if useLiDAR, cameraPosition == .back {
                    toggleDepthCapture(enabled: true)
                }

                if isSessionConfigured, !session.isRunning {
                    session.startRunning()
                    DispatchQueue.main.async { self.updateVideoRotation() }
                }
            }
        }
    }

    func stopSession() {
        guard session.isRunning else {
            return
        }
        Self.sessionQueue.async { [weak self] in
            guard let self else { return }
            if session.isRunning {
                session.stopRunning()
                DispatchQueue.main.async { self.detections = [] }
                LiDARManager.shared.stop()

                stopSpeech()
                SpeechManager.shared.stopSpeech()
                SpeechManager.shared.resetSpeechState()
            }
        }
    }

    // MARK: - Camera Controls

    func setTorchLevel(_ level: Float) {
        guard let device = currentDevice ?? session.inputs.compactMap({ ($0 as? AVCaptureDeviceInput)?.device }).first,
              device.hasTorch
        else {
            return
        }
        do {
            try device.lockForConfiguration()
            if level > 0 {
                try device.setTorchModeOn(level: level)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        } catch {}
    }

    func toggleCameraZoom() {
        // Save torch state before reconfiguring
        savedTorchLevel = currentTorchLevel
        DispatchQueue.main.async { self.isUltraWide.toggle() }
        reconfigureCamera()
    }

    func flipCamera() {
        stopSpeech() // Stop all speech immediately on camera flip
        // Save torch state before reconfiguring (but will be reset to 0 for front camera)
        savedTorchLevel = cameraPosition == .back ? currentTorchLevel : 0.0
        DispatchQueue.main.async {
            self.cameraPosition = self.cameraPosition == .back ? .front : .back
        }
        reconfigureCamera()
    }

    private func reconfigureCamera() {
        // Save current torch level before stopping session
        savedTorchLevel = currentTorchLevel

        Self.sessionQueue.async { [weak self] in
            guard let self else { return }

            if session.isRunning {
                session.stopRunning()
            }

            DispatchQueue.main.async {
                self.detections = []
                self.currentZoomLevel = 1.0
                if self.cameraPosition == .front {
                    self.isUltraWide = false
                    // Don't restore torch for front camera
                    self.savedTorchLevel = 0.0
                    if LiDARManager.shared.isActive {
                        LiDARManager.shared.stop()
                    }
                }
            }

            isSessionConfigured = false
            setupCamera()

            if isSessionConfigured {
                session.startRunning()
                // Restore torch level after a brief delay for camera to stabilize
                if savedTorchLevel > 0, cameraPosition == .back {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.currentTorchLevel = self.savedTorchLevel
                    }
                }
            }
        }
    }

    // MARK: - Speech Control (Delegated to SpeechManager)

    func stopSpeech() {
        SpeechManager.shared.stopSpeech()
    }

    func announceSpeechEnabled() {
        SpeechManager.shared.announceSpeechEnabled()
    }

    func playWelcomeMessage() {
        speechManager.playWelcomeMessage()
    }

    // MARK: - Session Management

    func clearDetections() {
        DispatchQueue.main.async { [weak self] in
            self?.detections = []
        }
    }

    func pauseCameraAndProcessing() {
        Self.sessionQueue.async { [weak self] in
            guard let self else { return }

            if session.isRunning {
                session.stopRunning()
                DispatchQueue.main.async { self.detections = [] }
                LiDARManager.shared.stop()
            }

            stopSpeech()
        }
    }

    func resumeCameraAndProcessing() {
        Self.sessionQueue.async { [weak self] in
            guard let self else { return }
            if !session.isRunning {
                if !isSessionConfigured {
                    setupCamera()
                }
                if isSessionConfigured {
                    session.startRunning()
                    if isLiDAREnabled {
                        LiDARManager.shared.setEnabled(true)
                        LiDARManager.shared.start()
                    }
                }
            }
        }
    }

    // MARK: - Frame Processing

    func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
        autoreleasepool {
            frameCounter += 1
            // updateFPS() is removed here to measure detection completions only

            guard frameCounter % processEveryNFrames == 0 else { return }

            guard !isProcessing else { return }
            guard session.isRunning else {
                DispatchQueue.main.async { self.detections = [] }
                return
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }

            ocrDelegate?.cameraViewModel(self, didOutputPixelBuffer: pixelBuffer)
            guard let yoloProcessor else {
                return
            }

            enableMemoryPressureRelief()
            isProcessing = true

            yoloProcessor.predictWithThermalLimits(
                image: pixelBuffer,
                isPortrait: currentOrientation.isPortrait,
                filterMode: filterMode,
                confidenceThreshold: confidenceThreshold
            ) { (results: [YOLODetection]) in
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.detections = results

                    if self.isLiDAREnabled, !results.isEmpty {
                        let pts: [(id: UUID, point: CGPoint)] = results.map { det in
                            let center = CGPoint(x: det.rect.midX, y: det.rect.midY)
                            return (det.id, center)
                        }
                        let metersByID = LiDARManager.shared.distancesInMeters(for: pts)
                        var feetByID: [UUID: Int] = [:]
                        for det in results {
                            if let m = metersByID[det.id] {
                                feetByID[det.id] = LiDARManager.roundedFeet(fromMeters: m)
                            }
                        }
                        self.lastDistancesFeet = feetByID
                    }

                    // FPS now measures detection completions per second, not input frames.
                    self.updateFPS()

                    // Speech processing (delegated to shared SpeechManager)
                    if !results.isEmpty {
                        SpeechManager.shared.processDetectionsForSpeech(results, lidarManager: LiDARManager.shared)
                    }
                }
            }
        }
    }

    private func updateFPS() {
        let timestamp = CACurrentMediaTime()
        lastFrameTimestamps.append(timestamp)
        if lastFrameTimestamps.count > Constants.maxFrameSamples {
            lastFrameTimestamps.removeFirst()
        }
        if lastFrameTimestamps.count > 1 {
            let timeSpan = lastFrameTimestamps.last! - lastFrameTimestamps.first!
            let fps = Double(lastFrameTimestamps.count - 1) / max(timeSpan, 0.001)
            DispatchQueue.main.async { self.framesPerSecond = fps }
        }
    }

    // MARK: - LiDAR Control Removed: toggleDepthCapture and onLiDARToggled deleted

    func toggleDepthCapture(enabled: Bool) {
        Self.sessionQueue.async { [weak self] in
            guard let self else { return }

            session.beginConfiguration()
            defer { self.session.commitConfiguration() }

            if enabled, cameraPosition == .back {
                // Remove existing depth output if any
                if let existingDepth = depthDataOutput {
                    session.removeOutput(existingDepth)
                    depthDataOutput = nil
                    depthDelegate = nil
                }

                // Create and configure depth output
                let depthOutput = AVCaptureDepthDataOutput()
                let delegate = DepthDataDelegate()

                depthOutput.setDelegate(delegate, callbackQueue: videoQueue)
                depthOutput.isFilteringEnabled = true

                if session.canAddOutput(depthOutput) {
                    session.addOutput(depthOutput)
                    depthDataOutput = depthOutput
                    depthDelegate = delegate

                    // Configure connection
                    if let connection = depthOutput.connection(with: .depthData) {
                        connection.isEnabled = true
                        if #available(iOS 17.0, *) {
                            if connection.isVideoRotationAngleSupported(0) {
                                connection.videoRotationAngle = 0
                            }
                        } else {
                            if connection.isVideoOrientationSupported {
                                connection.videoOrientation = .portrait
                            }
                        }
                    }
                }
            } else if !enabled {
                // Remove depth output
                if let depthOutput = depthDataOutput {
                    session.removeOutput(depthOutput)
                    depthDataOutput = nil
                    depthDelegate = nil
                }
            }
        }
    }

    // CRITICAL METHOD - CONNECTS UI TO DEPTH CAPTURE
    func onLiDARToggled() {
        // Read the current state directly from LiDARManager
        let isEnabled = LiDARManager.shared.isEnabled
        toggleDepthCapture(enabled: isEnabled)
    }

    func setLiDAR(enabled: Bool) {
        isLiDAREnabled = enabled
        useLiDAR = enabled
        LiDARManager.shared.setEnabled(enabled)
        if enabled {
            LiDARManager.shared.start()
            toggleDepthCapture(enabled: true)
        } else {
            LiDARManager.shared.stop()
            toggleDepthCapture(enabled: false)
        }
    }

    func setOCREnabled(_ enabled: Bool) {
        isOCREnabled = enabled
        reconfigureCamera()
    }

    // MARK: - Helper Methods

    private func configureDevice(_ device: AVCaptureDevice, _ configuration: (AVCaptureDevice) throws -> Void) {
        do {
            try device.lockForConfiguration()
            try configuration(device)
            device.unlockForConfiguration()
        } catch {
            // Handle error silently
        }
    }

    // MARK: - Camera Permission Handling

    func checkAndHandleCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if !granted {
                        self.presentCameraDeniedAlert()
                    }
                }
            }
        case .denied, .restricted:
            presentCameraDeniedAlert()
        @unknown default:
            break
        }
    }

    private func presentCameraDeniedAlert() {
        cameraPermissionAlert = CameraPermissionAlert(
            title: "Camera Access Needed",
            message: "This app requires access to your camera to function. Please allow camera access in Settings.",
            openSettings: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        )
    }

    // MARK: - Reinitialization

    func reinitialize() {
        // Reset torch state completely when reinitializing
        currentTorchLevel = 0.0
        savedTorchLevel = 0.0

        stopSession()
        // Removed direct calls to SpeechManager and LiDARManager here.
        // Resource lifecycle for Speech and LiDAR is now managed by ResourceManager, not by CameraViewModel.
        clearDetections()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            currentOrientation = .portrait
            isUltraWide = false
            currentZoomLevel = 1.0
            minimumZoomFactor = 1.0
            maximumZoomFactor = 5.0
            initialZoomFactor = 1.0

            detections = []
            framesPerSecond = 0
            filterMode = "all"
            confidenceThreshold = 0.39
            frameRate = 20

            useLiDAR = false
            isLiDAREnabled = false
            lastDistancesFeet = [:]

            lastFrameTimestamps = []

            frameCounter = 0
            isProcessing = false
            processEveryNFrames = 1

            cameraPosition = .back
            isOCREnabled = false
        }

        // Removed: LiDARManager.shared.stop()
        // Removed: LiDARManager.shared.setEnabled(false)
        // Removed: speechManager.resetSpeechState()
        // Resource lifecycle for Speech and LiDAR is now managed by ResourceManager, not by CameraViewModel.

        autoreleasepool {
            // Memory cleanup
        }
    }

    /// Fully tears down and rebuilds the camera session and all inputs/outputs.
    func forceReconfigureSession() {
        Self.sessionQueue.async { [weak self] in
            guard let self else { return }
            if session.isRunning {
                session.stopRunning()
            }
            // Remove all inputs
            session.inputs.forEach { self.session.removeInput($0) }
            // Remove all outputs
            session.outputs.forEach { self.session.removeOutput($0) }
            isSessionConfigured = false
            setupCamera()
            if isSessionConfigured, !session.isRunning {
                session.startRunning()
                DispatchQueue.main.async { self.updateVideoRotation() }
            }
        }
    }

    // MARK: - Cleanup Methods

    func shutdown() {
        stopSession()
        stopSpeech()
        SpeechManager.shared.stopSpeech()
        SpeechManager.shared.resetSpeechState()
        clearDetections()

        yoloProcessor = nil

        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
            orientationObserver = nil
        }

        if #available(iOS 17.0, *) {
            if let coordinator = rotationCoordinator as? AVCaptureDevice.RotationCoordinator {
                coordinator.removeObserver(self, forKeyPath: "videoRotationAngleForHorizonLevelCapture")
            }
        }

        rotationCoordinator = nil
        currentDevice = nil

        // Removed direct calls to SpeechManager and LiDARManager here.
        // Resource lifecycle for Speech and LiDAR is now managed by ResourceManager, not by CameraViewModel.

        autoreleasepool {
            // Release retained objects
        }
    }

    func setSessionPresetIfAvailable(_ preset: AVCaptureSession.Preset) {
        if session.canSetSessionPreset(preset) {
            session.beginConfiguration()
            session.sessionPreset = preset
            session.commitConfiguration()
        }
    }

    // MARK: - New LiDAR Notification Method

    /// Shows a LiDAR notification message for 2 seconds.
    func showLiDARNotification(_ message: String) {
        DispatchQueue.main.async {
            self.lidarNotificationMessage = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.lidarNotificationMessage = nil
            }
        }
    }

    // MARK: - New Public Methods for UI interactions

    func handleToggleCameraZoom() {
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
        toggleCameraZoom()
    }

    func handleFlipCamera() {
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
        flipCamera()
    }

    func handleToggleSpeech() {
        isSpeechEnabled.toggle()
        if isSpeechEnabled {
            announceSpeechEnabled()
        } else {
            stopSpeech()
        }
    }
}

// MARK: - CameraViewModel Aggressive Thermal Management Extension

extension CameraViewModel {
    private func setupThermalManagement() {
        ThermalManager.shared.$thermalState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.handleThermalChange(newState)
            }
            .store(in: &cancellables)
    }

    private func handleThermalChange(_ newState: ProcessInfo.ThermalState) {
        switch newState {
        case .nominal:
            restorePerformance()
        case .fair:
            applyThermalThrottling(level: 1)
        case .serious:
            applyThermalThrottling(level: 2)
        case .critical:
            applyThermalThrottling(level: 3)
        @unknown default:
            restorePerformance()
        }
    }

    private func applyThermalThrottling(level: Int) {
        // Adjust frame rate and detection processing based on thermal level
        switch level {
        case 1:
            frameRate = max(10, frameRate - 5)
            processEveryNFrames = 2
            setThermalOptimizedSessionPreset()
        case 2:
            frameRate = max(5, frameRate - 10)
            processEveryNFrames = 4
            setThermalOptimizedSessionPreset()
        case 3:
            frameRate = 5
            processEveryNFrames = 6
            setThermalOptimizedSessionPreset()
            takeProcessingBreak()
        default:
            restorePerformance()
        }
    }

    private func restorePerformance() {
        frameRate = 30
        processEveryNFrames = 1
        setSessionPresetIfAvailable(.hd1920x1080)
    }

    private func enableThermalBreaks() {
        // Optionally implement additional timer-based breaks or cooldowns here if needed
    }

    private func takeProcessingBreak() {
        // Pause processing briefly to reduce thermal load
        pauseCameraAndProcessing()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.resumeCameraAndProcessing()
        }
    }

    func enableMemoryPressureRelief() {
        // This can be called before intensive operations to reduce memory pressure
        if frameRate > 15 {
            frameRate = 15
            processEveryNFrames = 3
        }
    }

    private func setThermalOptimizedSessionPreset() {
        // Lower session preset for thermal savings if possible
        if session.canSetSessionPreset(.hd1280x720) {
            setSessionPresetIfAvailable(.hd1280x720)
        }
    }
}
