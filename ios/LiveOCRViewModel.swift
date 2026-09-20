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

// MARK: - Audio Route

/// Where the app's voice should come out.
///
/// Every speaking path used to call `overrideOutputAudioPort(.speaker)` every
/// time, to defeat the earpiece after the mic had been used. That is right with
/// nothing connected and wrong with anything connected: it drags the sound off
/// AirPods, headphones or a car stereo mid-sentence, and a route change is
/// hundreds of milliseconds of silence. Matt asked on 2026-09-19 whether the
/// app is smooth on AirPods throughout, and this is the one place that decides.
enum AudioRoute {
    /// True when nothing external is connected — no AirPods, no Bluetooth, no
    /// headphones, no CarPlay, no AirPlay, no USB or line out.
    static func outputIsBuiltIn(_ audio: AVAudioSession) -> Bool {
        let external: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .headphones, .headsetMic,
            .carAudio, .airPlay, .HDMI, .usbAudio, .lineOut,
        ]
        return !audio.currentRoute.outputs.contains { external.contains($0.portType) }
    }

    /// Point the voice at the loudspeaker only when there is nothing better.
    static func preferLoudspeakerIfNothingConnected(_ audio: AVAudioSession) {
        if outputIsBuiltIn(audio) {
            try? audio.overrideOutputAudioPort(.speaker)
        } else {
            try? audio.overrideOutputAudioPort(.none)
        }
    }
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

    /// Bring the audio route up BEFORE the first word. Activating the session
    /// and ducking other audio takes a moment, and whatever is spoken during that
    /// ramp gets clipped — which is why the "three" of the countdown was half
    /// missing (2026-09-12).
    /// When this is off the app stays quiet and hands the sentence to VoiceOver
    /// instead. Asked for on AppleVis by Cash (2026-09-12): with VoiceOver on,
    /// the app's own voice and VoiceOver talk over each other, and the person
    /// who needs it most hears two voices at once.
    static var speaksAloud: Bool {
        UserDefaults.standard.object(forKey: "speakAnswersAloud") as? Bool ?? true
    }

    /// The one way a sentence reaches the person, whichever voice is doing it.
    private func announceInstead(_ text: String) {
        guard !text.isEmpty else { return }
        // .announcement is the notification VoiceOver reads in the user's OWN
        // voice and rate, which is the whole point of the setting.
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// Open the audio route and let the duck ramp settle, ideally long before
    /// anything needs to be heard. Called when the mode appears as well as at
    /// the shutter, so by the time the countdown starts the session is already
    /// active and there is no ramp left to eat the front of "three".
    func warmAudioRoute() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audio.setActive(true)
        // Only force the loudspeaker when the sound would otherwise come out of
        // the earpiece. Overriding unconditionally fights AirPods, a car stereo
        // or any other connected output — it yanks the route back to the phone
        // mid-countdown, and a route change costs hundreds of milliseconds of
        // silence right where a number should be.
        AudioRoute.preferLoudspeakerIfNothingConnected(audio)
    }


    // MARK: - Spoken countdown
    //
    // The count is driven by the speech synthesizer itself, not by a timer.
    //
    // The old version spoke a word and then slept a flat second, so every gap
    // was one second minus however long the synthesizer took to actually start
    // — which varies, and is longest on the first word. It also called
    // stopSpeaking before each number, so a late start meant "two" chopped the
    // tail off "three", and it built a brand new haptic generator on every tick,
    // which is cold every time, so the buzz landed after the word or not at all.
    // Three separate sources of drift on the same second.
    //
    // Now all three numbers are handed to the synthesizer at once with a fixed
    // pause between them. It paces them itself, nothing interrupts anything, the
    // buzz fires from didStart so it lands on the word rather than near it, and
    // one prepared generator is reused. Matt, 2026-09-19: it has to be clear, on
    // time, and sound focused and controlled, on the speaker and on AirPods.

    private let countdownHaptic = UIImpactFeedbackGenerator(style: .medium)
    private var countdownUtterances: [AVSpeechUtterance] = []
    private var countdownTask: Task<Void, Never>?
    private var onCountdownFinished: (() -> Void)?

    /// Silence held after each number. The synthesizer owns this pause, so the
    /// spacing no longer depends on how fast it can start speaking.
    private static let countdownGap: TimeInterval = 0.45

    /// The number showing on the button, or nil when no count is running.
    @Published var countdownRemaining: Int?

    private static let countdownWords = [(3, "three"), (2, "two"), (1, "one")]

    /// Count down out loud, then call `onFire` on the main actor. Cancelling
    /// before it finishes never fires.
    func startCountdown(voiceIdentifier: String, onFire: @escaping () -> Void) {
        cancelCountdown()
        onCountdownFinished = onFire
        countdownHaptic.prepare()
        warmAudioRoute()

        // When the person has handed the talking to VoiceOver, the synthesizer
        // is not involved and there is nothing to pace against, so the count is
        // posted as announcements on a timer. VoiceOver decides the voice and
        // the rate; all we own here is the interval and the buzz.
        guard Self.speaksAloud else {
            countdownTask = Task { @MainActor [weak self] in
                for (number, word) in Self.countdownWords {
                    guard let self, !Task.isCancelled else { return }
                    countdownRemaining = number
                    countdownHaptic.impactOccurred()
                    countdownHaptic.prepare()
                    announceInstead(word)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard let self, !Task.isCancelled else { return }
                countdownRemaining = nil
                countdownTask = nil
                let fire = onCountdownFinished
                onCountdownFinished = nil
                fire?()
            }
            return
        }

        if speechSynthesizer.isSpeaking { speechSynthesizer.stopSpeaking(at: .immediate) }
        let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        countdownUtterances = Self.countdownWords.map { _, word in
            let utterance = AVSpeechUtterance(string: word)
            if let voice { utterance.voice = voice }
            utterance.rate = 0.5
            utterance.volume = 1.0
            utterance.postUtteranceDelay = Self.countdownGap
            return utterance
        }
        countdownRemaining = 3
        countdownUtterances.forEach { speechSynthesizer.speak($0) }
    }

    /// Back out of the count without taking the picture.
    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        onCountdownFinished = nil
        if !countdownUtterances.isEmpty {
            countdownUtterances = []
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        countdownRemaining = nil
    }

    /// Which number an utterance is, or nil when it is ordinary speech.
    private func countdownIndex(of utterance: AVSpeechUtterance) -> Int? {
        countdownUtterances.firstIndex { $0 === utterance }
    }

    func speak(text: String, voiceIdentifier: String, completion: @escaping () -> Void) {
        guard !text.isEmpty else { completion(); return }
        if !Self.speaksAloud {
            announceInstead(text)
            completion()
            return
        }
        // Force the loudspeaker: the camera or the mic can leave the route on the
        // earpiece, which makes the spoken description come out quiet.
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audio.setActive(true)
        AudioRoute.preferLoudspeakerIfNothingConnected(audio)
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
    /// The buzz rides on this, not on a timer — didStart is the moment the
    /// sound actually begins, so the number and the tap land together.
    func speechSynthesizer(_: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard let i = self.countdownIndex(of: utterance) else { return }
            self.countdownRemaining = Self.countdownWords[i].0
            self.countdownHaptic.impactOccurred()
            self.countdownHaptic.prepare()
        }
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            if let i = self.countdownIndex(of: utterance) {
                // Only the last number fires the shutter; the others just pass.
                guard i == self.countdownUtterances.count - 1 else { return }
                self.countdownUtterances = []
                self.countdownRemaining = nil
                let fire = self.onCountdownFinished
                self.onCountdownFinished = nil
                fire?()
                return
            }
            self.speechCompletionHandler?()
            self.speechCompletionHandler = nil
        }
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            // A cancelled countdown never takes the picture.
            guard self.countdownIndex(of: utterance) == nil else { return }
            self.speechCompletionHandler?()
            self.speechCompletionHandler = nil
        }
    }
}
