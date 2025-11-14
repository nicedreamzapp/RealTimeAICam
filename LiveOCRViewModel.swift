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

    // This method is now backgrounded using Swift Concurrency (Task.detached) for UI performance
    func processFrame(_ pixelBuffer: CVPixelBuffer, mode: OCRMode) {
        autoreleasepool {
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            // NEW: do nothing while user is reviewing/copying
            guard !isFrozen else { return }
            guard !isPinching else { return }
            let now = Date()
            guard now.timeIntervalSince(lastProcessedTime) >= processInterval else { return }
            lastProcessedTime = now
            guard !isProcessing else { return }

            let targetLanguage = (mode == .spanishToEnglish) ? "es-ES" : "en-US"
            if currentLanguage != targetLanguage {
                currentLanguage = targetLanguage
                textRecognitionRequest?.recognitionLanguages = (mode == .spanishToEnglish) ? ["es-ES", "es"] : ["en-US", "en"]
            }

            let request = self.textRecognitionRequest
            Task.detached { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.isProcessing = true
                }
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
                if let request {
                    do {
                        try handler.perform([request])
                    } catch {
                        await MainActor.run {
                            self.isProcessing = false
                        }
                    }
                    await MainActor.run {
                        request.cancel()
                    }
                }
            }
        }
    }

    // MARK: - On-Demand Translation (Updated for SimpleSpanishEngine)

    func translateSpanishText(completion: @escaping (Bool) -> Void) {
        guard !recognizedText.isEmpty else { completion(false); return }

        Task {
            let engineIsReady = await MainActor.run { FixedSpanishEngine.shared.isReady() }
            if !engineIsReady {
                await MainActor.run { self.isTranslatorLoading = true }
                // Wait for the engine to load by polling
                while await !(MainActor.run { FixedSpanishEngine.shared.isReady() }) {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                }
                await MainActor.run { self.isTranslatorLoading = false }
            }

            await MainActor.run { self.isFrozen = true }
            let textToTranslate = self.recognizedText // capture to avoid actor crossing

            let translation = await MainActor.run { FixedSpanishEngine.shared.translate(textToTranslate) }
            await MainActor.run {
                self.translatedText = translation
                self.isTranslated = true
                completion(true)
            }
        }
    }

    func translateSpanishTextWithConfidence(completion: @escaping (String?) -> Void) {
        guard !recognizedText.isEmpty else { completion(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            Task { @MainActor in
                let result = FixedSpanishEngine.shared.translate(self.recognizedText)
                DispatchQueue.main.async { completion(result) }
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
