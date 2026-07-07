import AVFoundation
import Combine
import CoreVideo
import SwiftUI
import Vision

// MARK: - Zoom Camera Manager (unchanged)

class ZoomCameraManager: NSObject, ObservableObject {
    @Published var currentZoomLevel: CGFloat = 1.0
    private var captureDevice: AVCaptureDevice?
    private var initialZoomFactor: CGFloat = 1.0
    func setup(device: AVCaptureDevice) { captureDevice = device }
    func handlePinchGesture(_ scale: CGFloat) {
        guard let device = captureDevice else { return }
        let newZoomFactor = initialZoomFactor * scale
        let clampedZoom = max(1.0, min(newZoomFactor, min(device.maxAvailableVideoZoomFactor, 5.0)))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clampedZoom
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.currentZoomLevel = clampedZoom }
        } catch {}
    }

    func setPinchGestureStartZoom() { initialZoomFactor = captureDevice?.videoZoomFactor ?? 1.0 }
}

// MARK: - Live OCR View Model (Updated for SimpleSpanishEngine)

final class LiveOCRViewModel: NSObject, ObservableObject {
    // MARK: - Properties

    @Published var recognizedText: String = ""
    @Published var translatedText: String = ""
    @Published var isProcessing: Bool = false
    @Published var isTranslated: Bool = false
    @Published var isUltraWide: Bool = false
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    @Published var isPinching: Bool = false
    @Published var isFrozen: Bool = false
    @Published var torchLevel: Float = 0.0
    @Published var isTranslatorLoading: Bool = false

    weak var cameraPreviewRef: CameraPreviewView?
    weak var cameraPreviewView: CameraPreviewView?

    let cameraManager = ZoomCameraManager()

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var textRecognitionRequest: VNRecognizeTextRequest?
    private var lastProcessedTime = Date()
    private var currentLanguage: String?
    private var speechCompletionHandler: (() -> Void)?

    private var processInterval: TimeInterval {
        switch DevicePerf.shared.tier {
        case .low: 1.2
        case .mid: 0.8
        case .high: 0.6
        }
    }

    // MARK: - Initialization

    override init() {
        super.init()
        setupTextRecognition()
        speechSynthesizer.delegate = self
        // Removed engine preloading here as per instructions
    }

    private func setupTextRecognition() {
        textRecognitionRequest = VNRecognizeTextRequest { [weak self] request, error in
            guard let self else { return }
            if let _ = error {
                request.cancel(); return
            }
            guard let observations = request.results as? [VNRecognizedTextObservation] else { request.cancel(); return }
            let recognizedStrings = observations.compactMap { $0.topCandidates(1).first?.string }
            let fullText = recognizedStrings.joined(separator: " ")
            DispatchQueue.main.async {
                guard !self.isFrozen else {
                    self.isProcessing = false
                    return
                }
                let changed = (self.recognizedText != fullText)
                self.recognizedText = fullText
                self.isProcessing = false
                if changed { self.isTranslated = false; self.translatedText = "" }
            }
        }
        switch DevicePerf.shared.tier {
        case .low:
            textRecognitionRequest?.recognitionLevel = .fast
            textRecognitionRequest?.usesLanguageCorrection = false
            textRecognitionRequest?.minimumTextHeight = 0.03
        case .mid:
            textRecognitionRequest?.recognitionLevel = .accurate
            textRecognitionRequest?.usesLanguageCorrection = true
            textRecognitionRequest?.minimumTextHeight = 0.02
        case .high:
            textRecognitionRequest?.recognitionLevel = .accurate
            textRecognitionRequest?.usesLanguageCorrection = true
            textRecognitionRequest?.minimumTextHeight = 0.015
        }
    }

    // MARK: - Frame Processing (OCR Only)

    // Called on the capture videoQueue (a serial background queue). Vision OCR runs
    // synchronously here so the CVPixelBuffer stays valid for the whole request —
    // the previous Task.detached path could read a buffer AVFoundation had already
    // recycled (alwaysDiscardsLateVideoFrames = true), risking garbled text/crashes.
    func processFrame(_ pixelBuffer: CVPixelBuffer, mode: OCRMode) {
        autoreleasepool {
            // Do nothing while user is reviewing/copying
            guard !isFrozen else { return }
            guard !isPinching else { return }
            let now = Date()
            guard now.timeIntervalSince(lastProcessedTime) >= processInterval else { return }
            lastProcessedTime = now

            let targetLanguage = (mode == .spanishToEnglish) ? "es-ES" : "en-US"
            if currentLanguage != targetLanguage {
                currentLanguage = targetLanguage
                textRecognitionRequest?.recognitionLanguages = (mode == .spanishToEnglish) ? ["es-ES", "es"] : ["en-US", "en"]
            }

            guard let request = textRecognitionRequest else { return }
            // Serial videoQueue + synchronous perform = frames are naturally serialized,
            // so no overlap guard is needed. The completion handler publishes results on main.
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: - On-Demand Translation

    /// Matt's call 2026-07-06: everything ships inside the app with zero
    /// downloads, so Apple's neural translator (which needs a one-time language
    /// pack download) stays OFF. Flip to true to re-enable the iOS 18+ path.
    private static let useAppleTranslation = false
    private static let appleTranslationMinChars = 120

    /// Non-nil while a request is waiting on Apple's translator; observed by
    /// LiveOCRView's translationTask modifier (iOS 18+ only).
    @Published var appleTranslationRequest: String?
    private var pendingAppleCompletion: ((Bool) -> Void)?

    func translateSpanishText(completion: @escaping (Bool) -> Void) {
        guard !recognizedText.isEmpty else { completion(false); return }
        isFrozen = true
        let text = recognizedText

        if Self.useAppleTranslation, #available(iOS 18.0, *), text.count >= Self.appleTranslationMinChars {
            pendingAppleCompletion = completion
            appleTranslationRequest = text // LiveOCRView's translationTask takes over
            return
        }
        translateWithEngine(text, completion: completion)
    }

    /// Called by the view when Apple's translator finishes (or fails — nil result
    /// falls back to the offline rule engine so translation always produces output).
    func completeAppleTranslation(_ result: String?) {
        let completion = pendingAppleCompletion
        pendingAppleCompletion = nil
        let requested = appleTranslationRequest
        appleTranslationRequest = nil

        if let result, !result.isEmpty {
            translatedText = result
            isTranslated = true
            completion?(true)
        } else if let requested {
            translateWithEngine(requested, completion: completion ?? { _ in })
        }
    }

    private func translateWithEngine(_ text: String, completion: @escaping (Bool) -> Void) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let engine = FixedSpanishEngine.shared

            // Wait for the dictionary, but never forever: a corrupt/missing data
            // file used to leave this loop spinning and the feature dead with no
            // message. 10s is generous for a one-time load.
            if !engine.isReady() {
                await MainActor.run { self?.isTranslatorLoading = true }
                let deadline = Date().addingTimeInterval(10)
                while !engine.isReady(), Date() < deadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                await MainActor.run { self?.isTranslatorLoading = false }
            }

            guard engine.isReady() else {
                await MainActor.run {
                    self?.translatedText = "Translation data couldn't load. Please close and reopen the app."
                    self?.isTranslated = true
                    completion(false)
                }
                return
            }

            // Heavy regex work runs right here on the background executor.
            let translation = engine.translate(text)
            await MainActor.run {
                self?.translatedText = translation
                self?.isTranslated = true
                completion(true)
            }
        }
    }

    // MARK: - Reset Translation

    func resetTranslation() {
        isTranslated = false
        translatedText = ""
        isFrozen = false
    }

    /// Resume OCR processing after freezing for translation/copy
    func continueReading() {
        isFrozen = false
        // Optional: reset translated flag if desired
        // isTranslated = false
    }

    // MARK: - Speech

    func speak(text: String, voiceIdentifier: String, completion: @escaping () -> Void) {
        guard !text.isEmpty else { completion(); return }
        if speechSynthesizer.isSpeaking { speechSynthesizer.stopSpeaking(at: .immediate) }
        speechCompletionHandler = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let utterance = AVSpeechUtterance(string: text)
            if let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) { utterance.voice = voice }
            utterance.rate = 0.5
            utterance.volume = 0.9
            self.speechSynthesizer.speak(utterance)
        }
    }

    func stopSpeaking() {
        if speechSynthesizer.isSpeaking { speechSynthesizer.stopSpeaking(at: .immediate) }
    }

    // MARK: - Text Management

    func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        SettingsOverlayView.addToCopyHistory(text)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    func clearText() {
        recognizedText = ""
        translatedText = ""
        isTranslated = false
        isFrozen = false
    }

    // MARK: - Camera Controls

    func toggleCameraZoom() {
        isUltraWide.toggle()
    }

    func flipCamera() {
        cameraPosition = (cameraPosition == .back ? .front : .back)
        if cameraPosition == .front { isUltraWide = false }
    }

    func setCameraPreview(_ preview: CameraPreviewView) { cameraPreviewView = preview }

    // Added handler methods with haptic feedback and torch handling

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

    func handleToggleTorch(level: Float) {
        torchLevel = level
        // Optionally add feedback here if desired
    }

    // MARK: - Session Management

    func startSession() {}
    func stopSession() { stopSpeaking() }
    func shutdown() {
        cameraPreviewView?.stopSession()
        stopSession()
        clearText()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension LiveOCRViewModel: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speechCompletionHandler?(); self.speechCompletionHandler = nil }
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speechCompletionHandler?(); self.speechCompletionHandler = nil }
    }
}
