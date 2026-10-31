import AVFoundation
import Combine
import CoreImage
import SwiftUI
import UIKit

/// The latest camera frame, kept from the 601 detector's own camera so Talk
/// never opens a second capture session. Filled on the video queue.
final class TalkFrames: CameraViewModelOCRDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func cameraViewModel(_: CameraViewModel, didOutputPixelBuffer pixelBuffer: CVPixelBuffer) {
        lock.lock(); latest = pixelBuffer; lock.unlock()
    }

    /// The frame on screen right now as an upright photo (the detector's
    /// connection already turns it level with the horizon).
    func current() -> UIImage? {
        lock.lock(); let buffer = latest; lock.unlock()
        guard let buffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    func clear() {
        lock.lock(); latest = nil; lock.unlock()
    }
}

/// Talk's voice: the app voice the person picked (same voice and rate as
/// every other screen), with a queue so streamed sentences follow each other,
/// and a way to know when it has gone quiet. When the app voice is turned off
/// the words go to VoiceOver instead, as everywhere else in the app.
@MainActor
final class TalkVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var pending = 0
    private var announceUntil = Date.distantPast
    private var quietCheck: Task<Void, Never>?
    /// Called once the queue is empty and nothing is playing.
    var onQuiet: (() -> Void)?
    /// Called when the first utterance after `markTurn()` starts playing.
    var onFirstWords: (() -> Void)?
    private var turnStarted = false

    override init() {
        super.init()
        synth.delegate = self
        // Play inside the app's own play-and-record session, never a second one.
        synth.usesApplicationAudioSession = true
    }

    private var speaksAloud: Bool {
        UserDefaults.standard.object(forKey: "speakAnswersAloud") as? Bool ?? true
    }

    var isBusy: Bool { pending > 0 || synth.isSpeaking || Date() < announceUntil }

    /// The next utterance that starts is the first words of a new answer.
    func markTurn() { turnStarted = false }

    func say(_ raw: String) {
        let text = SpeakableText.spoken(raw)
        guard !text.isEmpty else { return }
        guard speaksAloud else {
            UIAccessibility.post(notification: .announcement, argument: text)
            let start = max(Date(), announceUntil)
            announceUntil = start.addingTimeInterval(SpeechManager.estimatedAnnouncementSeconds(text))
            if !turnStarted { turnStarted = true; onFirstWords?() }
            scheduleQuietCheck()
            return
        }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(identifier: SpeechManager.shared.selectedVoiceIdentifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        u.rate = 0.5
        pending += 1
        synth.speak(u)
    }

    func stop() {
        quietCheck?.cancel()
        announceUntil = .distantPast
        pending = 0
        synth.stopSpeaking(at: .immediate)
    }

    private func scheduleQuietCheck() {
        quietCheck?.cancel()
        quietCheck = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                if !self.isBusy { self.onQuiet?(); return }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didStart _: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.turnStarted { self.turnStarted = true; self.onFirstWords?() }
        }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        Task { @MainActor in
            self.pending = max(0, self.pending - 1)
            self.scheduleQuietCheck()
        }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        Task { @MainActor in self.pending = max(0, self.pending - 1) }
    }
}

/// The streamed answer, shared between the engine's thread (which writes)
/// and the main thread (which speaks). `alive` false stops the engine.
final class TalkStreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stream = TalkSentenceStream()
    private var _alive = true
    private(set) var spoken: [String] = []
    private(set) var lastText = ""

    var alive: Bool { lock.lock(); defer { lock.unlock() }; return _alive }
    func cancel() { lock.lock(); _alive = false; lock.unlock() }

    func feed(_ text: String, final: Bool = false) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard _alive else { return [] }
        if !final { lastText = text }
        let out = stream.feed(text, final: final).filter { !OnDeviceVisionNarrator.isRetakeAdvice($0) }
        spoken += out
        return out
    }
}

/// Talk to the camera: hands-free questions about what the camera sees, all
/// on the phone. See TalkBrain.swift for the design.
@MainActor
final class TalkController: ObservableObject {
    enum Phase: Equatable {
        case starting, listening, thinking, answering, off
        case failed(String)

        /// Big status words on screen, and what VoiceOver says for it.
        var words: String {
            switch self {
            case .starting: "Starting"
            case .listening: "Listening"
            case .thinking: "Thinking"
            case .answering: "Answering"
            case .off: "Talk is off"
            case let .failed(why): why
            }
        }
    }

    static let greeting = "I'm watching. What do you want to know?"

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var heard = ""
    @Published private(set) var spokenAnswer = ""
    /// Seconds from the last word of the question to the first word spoken.
    @Published private(set) var lastSpeed: Double?

    let frames = TalkFrames()
    private let listener = TalkListener()
    private let voice = TalkVoice()
    private var scene = TalkSceneMemory()
    private var detectionsSub: AnyCancellable?
    private var current: TalkStreamBox?
    private var turn = 0
    private var answerDone = true
    private var questionEndedAt: Date?
    private var onEnd: (() -> Void)?
    private var lifecycle: [NSObjectProtocol] = []
    private var running = false

    // MARK: Start and stop

    func start(camera: CameraViewModel, onEnd: @escaping () -> Void) {
        guard !running else { return }
        running = true
        self.onEnd = onEnd
        // The detector keeps running every frame; its own voice stays quiet
        // so it never talks over an answer.
        SpeechManager.shared.stopSpeech()
        camera.ocrDelegate = frames
        detectionsSub = camera.$detections.sink { [weak self] dets in
            let seen = dets.map { TalkSeen(name: $0.className, box: $0.rect) }
            self?.scene.update(seen, at: Date())
        }
        voice.onQuiet = { [weak self] in self?.voiceWentQuiet() }
        voice.onFirstWords = { [weak self] in self?.firstWordsSpoken() }
        listener.onQuestion = { [weak self] text, at in self?.heardQuestion(text, endedAt: at) }
        listener.onBargeIn = { [weak self] in self?.interrupt(replay: true) }
        listener.onPartial = { [weak self] text in self?.heard = text }
        let center = NotificationCenter.default
        lifecycle = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pause() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resume() }
            },
        ]
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            if let failure = await listener.start() {
                let why = failure == .notAllowed
                    ? "Talk needs the microphone and speech recognition. You can allow them in Settings."
                    : "Talk can't hear on this phone right now: offline speech recognition is not available."
                phase = .failed(why)
                SpeechManager.shared.speak(why)
                return
            }
            // Load the model while the greeting plays.
            Task.detached(priority: .utility) { await OnDeviceVisionNarrator.shared.warmUp(for: .scene) }
            speak(Self.greeting, thenListen: true)
        }
    }

    /// Everything off: mic, voice, model stream. The screen calls this when it goes away.
    func stop() {
        guard running else { return }
        running = false
        current?.cancel(); current = nil
        voice.onQuiet = nil
        voice.stop()
        listener.shutdown()
        detectionsSub = nil
        lifecycle.forEach(NotificationCenter.default.removeObserver)
        lifecycle = []
        frames.clear()
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .off
    }

    /// End Talk and leave the screen (the Stop button, the escape gesture, or "goodbye").
    func end() {
        let leave = onEnd
        stop()
        leave?()
    }

    private func pause() {
        guard running else { return }
        current?.cancel(); current = nil
        voice.stop()
        listener.stopListening()
        listener.watchWhileSpeaking(false)
    }

    private func resume() {
        guard running, listener.isRunning, !listener.isListening, phase != .thinking else { return }
        beginListening(tone: true)
    }

    // MARK: Turn taking

    /// Stop talking and listen now: the big button, a VoiceOver magic tap,
    /// or the person talking over the app (`replay` keeps their first words).
    func interrupt(replay: Bool = false) {
        guard running, listener.isRunning else { return }
        turn += 1
        current?.cancel(); current = nil
        answerDone = true
        voice.stop()
        listener.watchWhileSpeaking(false)
        if replay {
            phase = .listening
            heard = ""
            listener.listen(replay: true)
        } else {
            listener.stopListening()
            beginListening(tone: true)
        }
    }

    private func beginListening(tone: Bool) {
        guard running, listener.isRunning else { return }
        listener.watchWhileSpeaking(false)
        phase = .listening
        heard = ""
        let voiceOver = UIAccessibility.isVoiceOverRunning
        if voiceOver { UIAccessibility.post(notification: .announcement, argument: "Listening") }
        if tone { AimTonePlayer.shared.play(start: true) }
        // Let the tone (and VoiceOver's word) finish before the mic opens.
        let wait = (tone ? AimTones.duration + 0.08 : 0) + (voiceOver ? 0.7 : 0)
        let myTurn = turn
        Task { @MainActor in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard self.running, self.turn == myTurn, self.phase == .listening else { return }
            self.listener.listen()
        }
    }

    private func speak(_ text: String, thenListen: Bool) {
        answerDone = thenListen
        phase = .answering
        listener.watchWhileSpeaking(true)
        voice.say(text)
    }

    private func voiceWentQuiet() {
        guard running, answerDone, phase == .answering || phase == .thinking else { return }
        let myTurn = turn
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(TalkTiming.afterSpeaking * 1_000_000_000))
            guard self.running, self.turn == myTurn, !self.voice.isBusy, self.answerDone else { return }
            self.beginListening(tone: true)
        }
    }

    private func firstWordsSpoken() {
        guard let ended = questionEndedAt else { return }
        questionEndedAt = nil
        let seconds = Date().timeIntervalSince(ended)
        lastSpeed = (seconds * 10).rounded() / 10
        OnDeviceNarrator.log(read: "[talk first words]", said: nil,
                             extra: ["after_last_word": (seconds * 100).rounded() / 100,
                                     "after_end_of_question": ((seconds - TalkTiming.endOfSentence) * 100).rounded() / 100])
    }

    // MARK: Answering

    private func heardQuestion(_ question: String, endedAt: Date) {
        guard running else { return }
        heard = question
        switch TalkRouting.intent(of: question) {
        case .end:
            voice.markTurn()
            speak("Talk is off.", thenListen: false)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self.end()
            }
        case .repeatLast:
            voice.markTurn()
            questionEndedAt = endedAt
            speak(TalkMemory.shared.lastAnswer ?? "I haven't said anything yet. Ask me what you want to know.",
                  thenListen: true)
        case .ask:
            answer(question, endedAt: endedAt)
        }
    }

    private func answer(_ question: String, endedAt: Date) {
        turn += 1
        let myTurn = turn
        answerDone = false
        questionEndedAt = endedAt
        voice.markTurn()
        phase = .thinking
        spokenAnswer = ""
        // Talking over a slow answer still works.
        listener.watchWhileSpeaking(true)
        if UIAccessibility.isVoiceOverRunning, !(UserDefaults.standard.object(forKey: "speakAnswersAloud") as? Bool ?? true) {
            UIAccessibility.post(notification: .announcement, argument: "Thinking")
        }
        // The frame at the moment the question ended, plus what the detector sees.
        guard let photo = frames.current() else {
            speak("The camera isn't ready yet. Ask me again in a moment.", thenListen: true)
            return
        }
        let now = Date()
        let seen = scene.inView()
        let fresh = scene.newThings(at: now)
        let caption = scene.freshCaption(at: now)
        let history = TalkMemory.shared.recent()
        let whatsThis = TalkRouting.isWhatsThis(question)
        let named = TalkRouting.namedThing(in: question, among: seen)
        let box = TalkStreamBox()
        current = box

        Task { @MainActor in
            guard let cg = photo.cgImage else { return }
            let gate = await Task.detached(priority: .userInitiated) {
                FrameQualityGate.check(cg, checkDocumentEdges: true)
            }.value
            var isPage = TalkRouting.asksAboutPage(question)
            if !isPage, whatsThis, gate.documentFound == true {
                isPage = await OnDeviceVisionNarrator.hasReadableText(in: cg)
            }
            guard self.turn == myTurn, self.running else { return }
            var tip = TalkAim.tip(isPage: isPage, cutOffEdge: isPage ? gate.cutOffEdge : nil,
                                  named: named, qualityHint: gate.qualityHint)
            // A cut-off page is said first, as What's this? always has.
            if isPage, let t = tip, TalkAim.pageTip(cutOffEdge: gate.cutOffEdge) == t {
                self.say(t, turn: myTurn)
                tip = nil
            }
            let kind: PhotoKind = isPage ? .page : .scene
            // The detector's instant line when the model will take a while.
            let level = ModelPicker.level(for: kind)
            if !isPage, whatsThis, (ModelPicker.estimate(level, kind: kind) ?? 0) > TalkTiming.slowModel,
               let line = TalkPrompt.detectorLine(seen) {
                self.say(line + " Let me look closer.", turn: myTurn)
            }

            var final: String?
            if isPage, whatsThis {
                // "What's this?" at a page: exactly the What's this? page reader.
                final = await OnDeviceVisionNarrator.shared.narratePage(photo, gate: gate.logValue)
                if let final { self.say(final, turn: myTurn) }
            } else {
                let context = TalkPrompt.userText(question: question, seen: seen, newThings: fresh,
                                                  caption: caption, history: history)
                let reply = await OnDeviceVisionNarrator.shared.talk(context, about: photo, kind: kind) { text in
                    let sentences = box.feed(text)
                    if !sentences.isEmpty {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { sentences.forEach { self.say($0, turn: myTurn) } }
                        }
                    }
                    return box.alive
                }
                guard self.turn == myTurn, self.running else { return }
                if let reply {
                    if isPage {
                        // Not streamed (money is checked first): say it all now.
                        final = reply.text
                        self.say(reply.text, turn: myTurn)
                    } else {
                        // Whatever the stream had not finished yet.
                        box.feed(box.lastText, final: true).forEach { self.say($0, turn: myTurn) }
                        // Nothing was streamed at all (a retry path): the tidied answer.
                        if box.spoken.isEmpty { self.say(reply.text, turn: myTurn) }
                        final = box.spoken.isEmpty ? reply.text : box.spoken.joined(separator: " ")
                    }
                }
            }
            guard self.turn == myTurn, self.running else { return }
            if let final, !final.isEmpty {
                TalkMemory.shared.note(question: question, answer: final)
                if whatsThis, !isPage { self.scene.noteCaption(final, at: Date()) }
                self.spokenAnswer = final
            } else {
                self.say(OnDeviceVisionNarrator.isBundled
                    ? "Sorry, I couldn't work that one out. Please ask again."
                    : "The vision model isn't on this phone yet. It downloads in Settings, under Models.",
                    turn: myTurn)
            }
            if let tip { self.say(tip, turn: myTurn) }
            self.current = nil
            self.answerDone = true
            if !self.voice.isBusy { self.voiceWentQuiet() }
        }
    }

    /// One sentence of the current answer, unless the person has moved on.
    private func say(_ sentence: String, turn myTurn: Int) {
        guard running, turn == myTurn else { return }
        phase = .answering
        listener.watchWhileSpeaking(true)
        voice.say(sentence)
    }
}
