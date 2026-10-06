import AVFoundation
import Combine
import Foundation
import UIKit

// MARK: - Speech Manager (CONSOLIDATED - ONLY SPEECH SYSTEM IN APP)

/// Live Object Detection announcement rules (Android's SpeechAnnouncer follows
/// the same rules with the same numbers):
///
///  - announcementInterval = 1.0s   minimum gap between announcement cycles
///  - classCooldown        = 45.0s  per exact class name before it is said again
///  - interObjectDelay     = 0.8s   pause between queued names
///  - maxPerCycle          = 3      at most three names per cycle
///  - a cycle never starts while speaking or while the queue is draining
///  - the most central object is said first: distance of the box centre from
///    the frame centre, nearest first; a tie goes to the bigger box
///  - while draining, a queued name whose class is no longer in the latest
///    frame is skipped, so the app stops naming things you already moved off
///    (Warren, Blind Android Users, 2026-09-22)
///  - with the app's own voice off, the whole cycle goes to VoiceOver as ONE
///    announcement ("cup, laptop"), and no new cycle starts until it has had
///    time to be heard: 400 ms + 70 ms per character. One announcement per
///    frame is what cut Kareen off after the first letter (2026-09-25)
///  - the spoken text is the lowercase class name only, no confidence
///  - per-class entries older than 60s are cleaned up each cycle
class SpeechManager: NSObject, ObservableObject, @unchecked Sendable {
    // MARK: - Singleton Pattern to Prevent Multiple Instances

    static let shared = SpeechManager()

    // MARK: - Constants

    private enum Constants {
        static let announcementInterval: TimeInterval = 1.0 // Between announcement cycles
        static let classCooldown: TimeInterval = 45.0 // Back to 45 seconds as requested
        static let defaultVoiceKey = "selectedVoice"
        static let interObjectDelay: TimeInterval = 0.8 // Delay between objects in queue
        static let maxPerCycle = 3
    }

    // MARK: - Properties

    private let speechSynthesizer = AVSpeechSynthesizer()
    /// Queued names with the class each one came from, so a stale one can be skipped.
    private var announcementQueue: [(className: String, text: String)] = []
    /// Every class in the most recent frame.
    private var latestVisibleClasses: Set<String> = []
    private var isProcessingQueue = false
    private var announceGeneration = 0
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

    /// Every English voice installed on the phone, alphabetical.
    ///
    /// Kept in step with the picker's own list (see `premiumEnglishVoices` in
    /// UIComponents) after Joseph Weakland reported on AppleVis (2026-09-13)
    /// that voices he had enabled were invisible to the app. This one used to
    /// allow five hardcoded locales, then only voices whose identifier said
    /// premium or enhanced or whose name was one of six, then stopped at six.
    /// Any voice added after the fact failed all three tests.
    var availableEnglishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.name < $1.name }
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
            // .playback already prefers the speaker, but force it so a prior
            // record route (the mic for a follow-up question) can never leave
            // the voice stuck on the earpiece.
            //
            // Only when nothing is plugged in or paired, though. Forcing the
            // speaker unconditionally drags the audio off AirPods, a car stereo
            // or headphones every time the app speaks, and each of those route
            // changes costs hundreds of milliseconds of silence. Matt, 2026-09-19.
            if AudioRoute.outputIsBuiltIn(audioSession) {
                try? audioSession.overrideOutputAudioPort(.speaker)
            } else {
                try? audioSession.overrideOutputAudioPort(.none)
            }
        } catch {
            // Audio session setup failed - silently ignore
        }
    }

    // MARK: - Enhanced Detection Speech Processing (UPDATED FOR LIDAR + POSITION)

    func processDetectionsForSpeech(_ detections: [YOLODetection], lidarManager: LiDARManager) {
        guard isSpeechEnabled else { return }

        latestVisibleClasses = Set(detections.map(\.className))

        let now = Date()

        // Check timing
        let timeSinceLastAnnouncement = now.timeIntervalSince(lastAnnouncementTime)
        guard timeSinceLastAnnouncement >= Constants.announcementInterval else { return }

        // Don't interrupt current speech
        guard !isSpeaking, !isProcessingQueue else { return }

        // Most central first, at most three, each class only after its cooldown.
        // NO NORMALIZATION, USE EXACT NAMES.
        var objectsToAnnounce: [(className: String, text: String)] = []

        for detection in Self.centralFirst(detections) {
            guard objectsToAnnounce.count < Constants.maxPerCycle else { break }
            let exactObjectName = detection.className
            guard !objectsToAnnounce.contains(where: { $0.className == exactObjectName }) else { continue }
            let lastSpoken = lastSpokenByClass[exactObjectName] ?? .distantPast
            if now.timeIntervalSince(lastSpoken) >= Constants.classCooldown {
                objectsToAnnounce.append((exactObjectName, buildSpeechText(for: detection, lidarManager: lidarManager)))
                lastSpokenByClass[exactObjectName] = now
            }
        }

        lastAnnouncementTime = now

        if !objectsToAnnounce.isEmpty {
            if speaksAloud {
                announcementQueue = objectsToAnnounce
                processNextInQueue()
            } else {
                announceCycleToVoiceOver(objectsToAnnounce.map(\.text))
            }
        }

        cleanupOldEntries(now: now)
    }

    /// Detections ordered by how close the box centre is to the frame centre,
    /// nearest first; a tie goes to the bigger box. Boxes are normalised 0...1.
    static func centralFirst(_ detections: [YOLODetection]) -> [YOLODetection] {
        detections.sorted { a, b in
            let da = hypot(a.rect.midX - 0.5, a.rect.midY - 0.5)
            let db = hypot(b.rect.midX - 0.5, b.rect.midY - 0.5)
            if abs(da - db) > 0.0001 { return da < db }
            return a.rect.width * a.rect.height > b.rect.width * b.rect.height
        }
    }

    /// How long VoiceOver needs for a line before the next cycle may start.
    static func estimatedAnnouncementSeconds(_ text: String) -> TimeInterval {
        0.4 + 0.07 * Double(text.count)
    }

    /// The app's own voice is off: one VoiceOver announcement for the whole
    /// cycle, then hold the queue closed until it has had time to be heard.
    private func announceCycleToVoiceOver(_ names: [String]) {
        let line = SpeakableText.spoken(names.joined(separator: ", "))
        isProcessingQueue = true
        UIAccessibility.post(notification: .announcement, argument: line)
        announceGeneration += 1
        let generation = announceGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.estimatedAnnouncementSeconds(line)) { [weak self] in
            guard let self, announceGeneration == generation else { return }
            isProcessingQueue = false
        }
    }

    // MARK: - NEW: Build Speech Text Based on LiDAR Status

    private func buildSpeechText(for detection: YOLODetection, lidarManager: LiDARManager) -> String {
        // "Bat (Animal)" was read out with its label note; say just "bat".
        let objectName = SpeakableText.className(detection.className)

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
                return "\(objectName) \(positionWord) \(distanceFeet) \(distanceFeet == 1 ? "foot" : "feet")"
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
        // Skip anything that has left the frame since the cycle was queued.
        while let first = announcementQueue.first, !latestVisibleClasses.contains(first.className) {
            announcementQueue.removeFirst()
        }
        guard !announcementQueue.isEmpty else {
            isProcessingQueue = false
            return
        }
        let nextObject = announcementQueue.removeFirst()

        announceObject(nextObject.text)
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

        // Safety timeout - force continue if delegate fails. Scaled to the
        // utterance length (the old fixed 2s cut off anything longer and let a
        // stale timer clobber the NEXT utterance) and generation-guarded.
        announceGeneration += 1
        let generation = announceGeneration
        let timeout = max(2.0, Double(text.count) * 0.11 + 0.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, announceGeneration == generation, isSpeaking else { return }
            isSpeaking = false
            processNextInQueue()
        }
    }

    // MARK: - Public Speech Methods (REPLACE ALL OTHER SPEECH SYSTEMS)

    /// Off means the app stays quiet and lets VoiceOver read it instead — see
    /// LiveOCRViewModel.speaksAloud, same defaults key.
    private var speaksAloud: Bool {
        UserDefaults.standard.object(forKey: "speakAnswersAloud") as? Bool ?? true
    }

    func speak(_ rawText: String) {
        let text = SpeakableText.spoken(rawText)
        guard !text.isEmpty else { return }
        if !speaksAloud {
            UIAccessibility.post(notification: .announcement, argument: text)
            return
        }
        setupAudioSession() // re-assert the loudspeaker route before talking
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
            "The translator turns printed Spanish into English and reads it aloud. On iOS 18 and later it can translate other languages too, after a one-time download from Apple.",
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

        instructions.append("You can switch between front and back cameras.")
        if CameraCapabilities.hasUltraWideRear {
            instructions.append("Toggle wide and ultra-wide lenses.")
        }

        instructions.append(contentsOf: [
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
    func speakWithPauses(_ rawText: String) {
        let text = SpeakableText.spoken(rawText)
        guard !text.isEmpty else { return }
        if !speaksAloud {
            UIAccessibility.post(notification: .announcement, argument: text)
            return
        }
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
