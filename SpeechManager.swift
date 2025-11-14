import AVFoundation
import Combine
import Foundation

// MARK: - Speech Manager (CONSOLIDATED - ONLY SPEECH SYSTEM IN APP)

class SpeechManager: NSObject, ObservableObject, @unchecked Sendable {
    // MARK: - Singleton Pattern to Prevent Multiple Instances

    static let shared = SpeechManager()

    // MARK: - Constants

    private enum Constants {
        static let announcementInterval: TimeInterval = 1.0 // Between announcement cycles
        static let classCooldown: TimeInterval = 45.0 // Back to 45 seconds as requested
        static let defaultVoiceKey = "selectedVoice"
        static let interObjectDelay: TimeInterval = 0.8 // Delay between objects in queue
    }

    // MARK: - Properties

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var announcementQueue: [String] = []
    private var isProcessingQueue = false
    private var lastAnnouncementTime = Date.distantPast
    private var lastSpokenByClass: [String: Date] = [:] // Track by class name

    @Published var isSpeaking = false
    @Published var isSpeechEnabled = false
    @Published var selectedVoiceIdentifier: String {
        didSet {
            UserDefaults.standard.set(selectedVoiceIdentifier, forKey: Constants.defaultVoiceKey)
        }
    }

    // MARK: - Voice Properties

    var availableEnglishVoices: [AVSpeechSynthesisVoice] {
        let preferredLanguages = ["en-US", "en-GB", "en-AU", "en-IE", "en-ZA"]
        let preferredNames = ["Samantha", "Daniel", "Moira", "Karen", "Tessa", "Serena"]

        return AVSpeechSynthesisVoice.speechVoices()
            .filter { preferredLanguages.contains($0.language) }
            .filter { voice in
                let id = voice.identifier.lowercased()
                return id.contains("premium") || id.contains("enhanced") || preferredNames.contains(voice.name)
            }
            .sorted { $0.name < $1.name }
            .prefix(6)
            .map { $0 }
    }

    // MARK: - Initialization

    override init() {
        selectedVoiceIdentifier = UserDefaults.standard.string(forKey: Constants.defaultVoiceKey)
            ?? AVSpeechSynthesisVoice(language: "en-US")?.identifier ?? ""
        super.init()

        // CRITICAL: Set up audio session and delegate
        setupAudioSession()
        speechSynthesizer.delegate = self
    }

    // MARK: - Audio Session Setup

    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true)
        } catch {
            // Audio session setup failed - silently ignore
        }
    }

    // MARK: - Enhanced Detection Speech Processing (UPDATED FOR LIDAR + POSITION)

    func processDetectionsForSpeech(_ detections: [YOLODetection], lidarManager: LiDARManager) {
        guard isSpeechEnabled else { return }

        let now = Date()

        // Check timing
        let timeSinceLastAnnouncement = now.timeIntervalSince(lastAnnouncementTime)
        guard timeSinceLastAnnouncement >= Constants.announcementInterval else { return }

        // Don't interrupt current speech
        guard !isSpeaking, !isProcessingQueue else { return }

        // Find new objects to announce - NO NORMALIZATION, USE EXACT NAMES
        var objectsToAnnounce: [String] = []

        for detection in detections {
            let exactObjectName = detection.className // Use exact name, no normalization
            let lastSpoken = lastSpokenByClass[exactObjectName] ?? .distantPast
            let timeSinceSpoken = now.timeIntervalSince(lastSpoken)

            // Only announce if this EXACT object name hasn't been spoken recently
            if timeSinceSpoken >= Constants.classCooldown {
                // BUILD SPEECH STRING BASED ON LIDAR STATUS
                let speechText = buildSpeechText(for: detection, lidarManager: lidarManager)
                objectsToAnnounce.append(speechText)
                lastSpokenByClass[exactObjectName] = now
            }
        }

        lastAnnouncementTime = now

        // Start queue if we have objects
        if !objectsToAnnounce.isEmpty {
            announcementQueue = objectsToAnnounce
            processNextInQueue()
        }

        cleanupOldEntries(now: now)
    }

    // MARK: - NEW: Build Speech Text Based on LiDAR Status

    private func buildSpeechText(for detection: YOLODetection, lidarManager: LiDARManager) -> String {
        let objectName = detection.className.lowercased()

        // Check if LiDAR is active and enabled
        if lidarManager.isEnabled, lidarManager.isRunning {
            let center = CGPoint(x: detection.rect.midX, y: detection.rect.midY)

            // Try to get distance reading
            if let distanceFeet = lidarManager.distanceFeet(at: center),
               distanceFeet >= 1, distanceFeet <= 20
            {
                // Get position (L/R/C) based on center point
                let position = LiDARManager.horizontalBucket(forNormalizedX: center.x)
                let positionWord = convertPositionToWord(position)

                // Format: "bottle left 3 feet"
                return "\(objectName) \(positionWord) \(distanceFeet) feet"
            }
        }

        // Fallback: just object name (no confidence)
        return objectName
    }

    // MARK: - NEW: Convert L/R/C to spoken words

    private func convertPositionToWord(_ position: String) -> String {
        switch position {
        case "L": "left"
        case "R": "right"
        case "C": "center"
        default: "center"
        }
    }

    // MARK: - Queue Processing

    private func processNextInQueue() {
        guard !announcementQueue.isEmpty, !isSpeaking, isSpeechEnabled else {
            if announcementQueue.isEmpty {
                isProcessingQueue = false
            }
            return
        }

        isProcessingQueue = true
        let nextObject = announcementQueue.removeFirst()

        announceObject(nextObject)
    }

    // MARK: - Cleanup Old Entries

    private func cleanupOldEntries(now: Date) {
        // Remove entries older than 60 seconds to prevent memory buildup
        let cutoffTime = now.addingTimeInterval(-60.0)
        lastSpokenByClass = lastSpokenByClass.filter { _, lastTime in
            lastTime > cutoffTime
        }
    }

    // MARK: - Speech Announcements

    private func announceObject(_ text: String) {
        guard !isSpeaking else { return }

        let utterance = AVSpeechUtterance(string: text)
        if let chosenVoice = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier) {
            utterance.voice = chosenVoice
        }
        utterance.rate = 0.56
        utterance.pitchMultiplier = 1.0
        utterance.volume = 0.9

        speechSynthesizer.speak(utterance)

        // Safety timeout - force continue if delegate fails
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.isSpeaking == true {
                self?.isSpeaking = false
                self?.processNextInQueue()
            }
        }
    }

    // MARK: - Public Speech Methods (REPLACE ALL OTHER SPEECH SYSTEMS)

    func speak(_ text: String) {
        // Stop current speech if any
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        // Clear queue
        announcementQueue.removeAll()
        isProcessingQueue = false

        let utterance = AVSpeechUtterance(string: text)
        if let chosenVoice = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier) {
            utterance.voice = chosenVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = 0.5
        speechSynthesizer.speak(utterance)
    }

    func announceSpeechEnabled() {
        // Clear any existing queue
        announcementQueue.removeAll()
        isProcessingQueue = false

        let utterance = AVSpeechUtterance(string: "Speech enabled")
        if let chosenVoice = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier) {
            utterance.voice = chosenVoice
        }
        utterance.rate = 0.52
        utterance.volume = 0.9
        speechSynthesizer.speak(utterance)
    }

    func playWelcomeMessage() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        // Clear queue
        announcementQueue.removeAll()
        isProcessingQueue = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let utterance = AVSpeechUtterance(string: "Welcome to the real-time AI iOS Detection app. Thank you for choosing this voice!")
            if let chosenVoice = AVSpeechSynthesisVoice(identifier: self.selectedVoiceIdentifier) {
                utterance.voice = chosenVoice
            }
            utterance.rate = 0.5
            utterance.volume = 0.9
            self.speechSynthesizer.speak(utterance)
        }
    }

    // MARK: - Instructions Speech

    func speakInstructions(supportsLiDAR: Bool) {
        var instructions = [
            "Welcome to the RealTime AI Camera.",
            "Object Detection mode detects and labels up to six hundred and one objects in real time.",
            "English OCR mode reads printed English text aloud.",
            "Spanish to English mode translates printed Spanish text into English and reads it aloud.",
        ]

        if supportsLiDAR {
            instructions.append(
                "Tap the white ruler icon - it turns green when active - to enable LiDAR Distance Assist. This measures object distance, filters far-away objects, and stabilizes bounding boxes."
            )
        } else {
            instructions.append(
                "LiDAR Distance Assist is available only on LiDAR-equipped iPhone and iPad Pro models."
            )
        }

        instructions.append(contentsOf: [
            "You can switch between front and back cameras.",
            "Toggle wide and ultra-wide lenses.",
            "Adjust torch brightness between twenty five, fifty, seventy five, and one hundred percent.",
            "Pinch the screen to zoom in or out.",
            "Toggle text overlay on or off.",
            "Speak detected or translated text aloud.",
            "Copy text to the history for later use.",
            "Tap 'Play Complete Audio Tutorial' any time to hear these instructions again.",
        ])

        speak(instructions.joined(separator: " "))
    }

    // MARK: - Speech Control

    func stopSpeech() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isProcessingQueue = false
        announcementQueue.removeAll()
        lastAnnouncementTime = .distantPast
        isSpeechEnabled = false // Force-disable speech; prevents any late callback from speaking again
    }

    // MARK: - Reset Methods

    func resetSpeechState() {
        lastAnnouncementTime = .distantPast
        lastSpokenByClass.removeAll() // Clear class cooldowns
        isSpeaking = false
        isProcessingQueue = false
        announcementQueue.removeAll()
    }

    // MARK: - New Method: Speak with Pauses Based on Punctuation

    /// Speaks the given text by splitting it into segments based on punctuation marks,
    /// queuing each segment as a separate utterance with pauses after each segment depending on punctuation.
    /// - Parameter text: The input string to be spoken with pauses.
    func speakWithPauses(_ text: String) {
        // Stop current speech if any
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        // Clear any existing queue or processing state
        announcementQueue.removeAll()
        isProcessingQueue = false

        // Split input text into segments preserving punctuation marks as separate tokens
        // We'll use a regex that captures punctuation marks as separate segments
        // Punctuation marks to split on: . ! ? , ;
        // Use regex to split and keep delimiters
        let pattern = #"([^.!?,;]+[.!?,;]?)"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])

        var segmentsWithPunctuation: [String] = []
        if let regex {
            let nsText = text as NSString
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let segment = nsText.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty {
                    segmentsWithPunctuation.append(segment)
                }
            }
        } else {
            // Fallback: just use the whole text
            segmentsWithPunctuation = [text]
        }

        // Prepare queue of utterances with pause times based on punctuation
        var utterancesWithPause: [(utterance: AVSpeechUtterance, pause: TimeInterval)] = []

        for segment in segmentsWithPunctuation {
            // Determine last character punctuation
            let lastChar = segment.last

            // Determine pause duration
            let pauseDuration: TimeInterval = switch lastChar {
            case ".", "!", "?":
                0.7
            case ",", ";":
                0.3
            default:
                0.1
            }

            // Create utterance
            let utterance = AVSpeechUtterance(string: segment)
            if let chosenVoice = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier) {
                utterance.voice = chosenVoice
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            }
            utterance.rate = 0.5
            utterance.pitchMultiplier = 1.0
            utterance.volume = 0.9

            utterancesWithPause.append((utterance, pauseDuration))
        }

        // Use a queue to speak each segment consecutively with proper pause
        // Use delegate methods to know when an utterance finished,
        // so we will manage a separate queue for this method (to not conflict with the main announcementQueue).
        speakUtterancesWithPauses(utterancesWithPause)
    }

    // MARK: - Private helper for speakWithPauses

    private var speakWithPausesQueue: [(utterance: AVSpeechUtterance, pause: TimeInterval)] = []
    private var isSpeakingWithPauses = false

    private func speakUtterancesWithPauses(_ utterancesWithPause: [(utterance: AVSpeechUtterance, pause: TimeInterval)]) {
        // If currently speaking with pauses, stop first
        if isSpeakingWithPauses {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        speakWithPausesQueue = utterancesWithPause
        isSpeakingWithPauses = true

        speakNextWithPause()
    }

    private func speakNextWithPause() {
        guard !speakWithPausesQueue.isEmpty else {
            isSpeakingWithPauses = false
            return
        }

        let next = speakWithPausesQueue.removeFirst()
        speechSynthesizer.speak(next.utterance)

        // Schedule timer to wait pause after utterance finishes speaking
        // We rely on delegate to notify finish, so pause timer will be scheduled there.
        // But we keep pause duration here to use when finished.
        currentPauseDuration = next.pause
    }

    // Store current pause duration after utterance finish
    private var currentPauseDuration: TimeInterval = 0
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_: AVSpeechSynthesizer, didStart _: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.isSpeaking = true
        }
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // If currently speaking with pauses mode
            if isSpeakingWithPauses {
                isSpeaking = false
                // After the pause duration, speak next segment if any
                DispatchQueue.main.asyncAfter(deadline: .now() + currentPauseDuration) {
                    self.speakNextWithPause()
                }
                return
            }

            // Normal speech queue processing
            isSpeaking = false
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.interObjectDelay) {
                self.processNextInQueue()
            }
        }
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.isSpeaking = false
            self?.isProcessingQueue = false
            self?.announcementQueue.removeAll()

            // Also cancel speakWithPauses if active
            self?.isSpeakingWithPauses = false
            self?.speakWithPausesQueue.removeAll()
        }
    }
}
