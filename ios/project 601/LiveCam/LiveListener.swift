// Live Cam's ears (ported from Moonstone's LiveListener, 2026-11-04): one audio engine for the whole visit,
// Apple's recognizer on the phone only (requiresOnDeviceRecognition, so it works in airplane mode), in Your
// language when the phone can recognize it offline, else English. While Live Cam speaks, the words heard are
// handed to the owner (onBargeHeard) and nothing else happens: Matt 11/6, "It shouldn't stop speaking when it hears
// me cough... murmurs or any sound at all. It should only stop speaking when it hears a legitimate question toward
// it." Sound alone never interrupts; the owner decides from the words (LiveWords.isBargeIn) and, for a real
// question, takes the same recognition on as the question (takeBargeAsQuestion), so the first words are kept.
import AVFoundation
import Foundation
import Speech

@MainActor
final class LiveListener {
    enum Failure: Error { case notAllowed, unavailable }

    /// A finished utterance: text, when its last word was heard, the recognizer's average word
    /// confidence (nil if it gave none) and whether it was the recognizer's final result.
    var onQuestion: ((String, Date, Double?, Bool) -> Void)?
    /// While Live Cam talks: the words heard so far (and the recognizer's confidence on a final result).
    var onBargeHeard: ((String, Double?) -> Void)?
    /// Transcribing only to judge a barge-in: no question is delivered from it unless the owner takes it on.
    private(set) var bargeOnly = false
    /// The mic is muted by the person: nothing is transcribed while it talks either.
    var muted = false
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// The recognizer kept failing the moment it started: listening has stopped for this visit.
    var onGaveUp: (() -> Void)?
    /// A backed-off retry is due. The owner restarts listening only if it is still waiting for a question
    /// (never while it is speaking or thinking, or it would hear itself).
    var onRetry: (() -> Void)?

    /// A recognizer failure this soon after listening started, with nothing heard, counts as a quick failure.
    nonisolated static let quickFailure: TimeInterval = 2
    /// Wait before trying again after the 1st, 2nd, 3rd quick failure in a row; one more and it gives up.
    nonisolated static let retryDelays: [TimeInterval] = [1, 2, 5]
    /// The wait before the next try after `failures` quick failures in a row, or nil to stop trying.
    nonisolated static func retryDelay(afterQuickFailures failures: Int) -> TimeInterval? {
        (1 ... retryDelays.count).contains(failures) ? retryDelays[failures - 1] : nil
    }
    private(set) var quickFailures = 0
    private(set) var gaveUp = false
    private(set) var lastRetryDelay: TimeInterval?
    private var retryTask: Task<Void, Never>?

    /// Test aid: no microphone; recorded audio comes in through `inject`.
    var feedMode = false

    private var recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var transcript = ""
    private(set) var lastChange = Date()
    /// Last time the mic heard something voice-loud; the end of a question is when this goes quiet.
    private(set) var lastLoudAt = Date()
    nonisolated static let voiceLevel: Float = -40
    private(set) var endReason = ""
    private var listenStarted = Date()
    private var watchdog: Task<Void, Never>?
    private(set) var isRunning = false
    private(set) var isListening = false
    private let tap = LiveTapState()

    /// The first time: iOS hasn't asked for the microphone or speech recognition yet, so Live Cam says why
    /// before the two prompts appear.
    static var willAskPermission: Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined || AVAudioApplication.shared.recordPermission == .undetermined
    }

    func start() async -> Failure? {
        guard !isRunning else { return nil }
        let speechOK = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speechOK else { return .notAllowed }
        recognizer = YourLanguageVoice.recognizer()
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { return .unavailable }
        if feedMode { isRunning = true; return nil }
        let micOK = await withCheckedContinuation { c in AVAudioApplication.requestRecordPermission { c.resume(returning: $0) } }
        guard micOK else { return .notAllowed }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default,
                              options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
            try s.setActive(true)
        } catch { return .unavailable }
        let node = engine.inputNode
        #if !targetEnvironment(simulator)
        // Echo cancellation keeps most of Live Cam's own voice out of the mic, so a barge-in can be heard.
        if (try? node.setVoiceProcessingEnabled(true)) != nil {
            node.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        #endif
        node.removeTap(onBus: 0)
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return .unavailable }
        let state = tap
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let (event, level) = state.handle(buffer)
            _ = event
            Task { @MainActor in
                if level > LiveListener.voiceLevel { self?.lastLoudAt = Date() }
                self?.onLevel?(level)
            }
        }
        engine.prepare()
        do { try engine.start() } catch { node.removeTap(onBus: 0); return .unavailable }
        isRunning = true
        return nil
    }

    /// Tests: mark the ears as started without a microphone (feed mode only).
    func startForTest() { if feedMode { isRunning = true } }

    func shutdown() {
        stopMic()
        guard !feedMode else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The microphone off (engine stopped, tap removed) but the audio session left as it is, so the voice can
    /// still talk. Used when recognition gave up: the mic indicator goes out, nothing keeps listening.
    func stopMic() {
        stopListening()
        tap.speaking(false)
        isRunning = false
        guard !feedMode else { return }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        #if !targetEnvironment(simulator)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        #endif
    }

    /// Test feed: one buffer, handled exactly like a mic buffer.
    func inject(_ buffer: AVAudioPCMBuffer) {
        let (_, level) = tap.handle(buffer)
        onLevel?(level)
    }

    func listen(replay: Bool = false) {
        if bargeOnly { stopListening() }   // it stopped talking: a fresh listen for the next question
        start(replay: replay, barge: false)
    }

    private func start(replay: Bool, barge: Bool) {
        guard isRunning, !isListening, !gaveUp, let recognizer else { return }
        bargeOnly = barge
        retryTask?.cancel(); retryTask = nil
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true   // never the network: airplane mode works
        req.taskHint = .search
        request = req
        transcript = ""
        listenStarted = Date(); lastChange = Date(); lastLoudAt = Date()
        dropWords = 0
        isListening = true
        tap.startFeeding(req, replay: replay)
        finishing = false
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            let segs = result?.bestTranscription.segments ?? []
            // On-device results often carry 0 confidences: average only the real ones, none if there are none.
            let real = segs.map { Double($0.confidence) }.filter { $0 > 0 }
            let conf: Double? = final && !real.isEmpty ? real.reduce(0, +) / Double(real.count) : nil
            Task { @MainActor in
                guard let self, self.isListening, self.request === req else { return }
                if self.bargeOnly {
                    // While it talks: only words, judged by the owner; a failure just ends this watch quietly.
                    if let text, text != self.transcript { self.lastChange = Date(); self.transcript = text; self.onBargeHeard?(text, conf) }
                    if final || failed { self.stopListening(); if !failed { self.start(replay: false, barge: true) } }
                    return
                }
                if let text, text != self.transcript {
                    if !self.finishing { self.lastChange = Date() }
                    self.transcript = text; self.onPartial?(text)
                }
                if final { self.deliver(confidence: conf, isFinal: true) } else if failed { self.recognizerFailed() }
            }
        }
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            while let self, self.isListening, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                let now = Date()
                // Listening has held past the quick-failure window: the failures before it were not "in a row".
                if self.quickFailures > 0, now.timeIntervalSince(self.listenStarted) >= Self.quickFailure { self.quickFailures = 0 }
                let wordsQuiet = now.timeIntervalSince(self.lastChange), micQuiet = now.timeIntervalSince(self.lastLoudAt)
                if self.bargeOnly {
                    // Side talk that wasn't for it: once it stops, start over so old words never pile onto new ones.
                    if !self.transcript.isEmpty, wordsQuiet > LiveTiming.bargeForget {
                        self.stopListening(); self.start(replay: false, barge: true); return
                    }
                    if now.timeIntervalSince(self.listenStarted) > LiveTiming.idleRestart { self.stopListening(); self.start(replay: false, barge: true); return }
                    continue
                }
                if !self.finishing, LiveTiming.questionEnded(heard: !self.transcript.isEmpty, wordsQuiet: wordsQuiet, micQuiet: micQuiet, text: self.transcript) {
                    self.endReason = wordsQuiet >= LiveTiming.endOfSpeech ? "words stopped" : "mic quiet"
                    self.finish()
                } else if self.transcript.isEmpty, now.timeIntervalSince(self.listenStarted) > LiveTiming.idleRestart {
                    self.stopListening(); self.listen()
                }
            }
        }
    }

    func stopListening() {
        retryTask?.cancel(); retryTask = nil
        watchdog?.cancel(); watchdog = nil
        tap.stopFeeding()
        request?.endAudio()
        task?.cancel()
        task = nil; request = nil
        isListening = false
        bargeOnly = false
    }

    /// While Live Cam speaks or thinks: the words heard go to onBargeHeard (sound alone never interrupts).
    func watchForBargeIn(_ on: Bool) {
        tap.speaking(on)
        if on {
            guard !muted else { return }
            if isListening, !bargeOnly { stopListening() }
            if !isListening { start(replay: false, barge: true) }
        } else if bargeOnly {
            stopListening()
        }
    }

    /// The words heard while it talked were a real question to it: the same recognition carries on as the question
    /// (end of speech and delivery as usual), so nothing said so far is lost.
    func takeBargeAsQuestion(dropWords: Int = 0) {
        guard isListening, bargeOnly else { listen(); return }
        bargeOnly = false
        self.dropWords = dropWords
        tap.speaking(false)
        lastChange = Date()
    }

    /// The language being heard (the recognizer's), for the barge-in word lists.
    var heardLang: String { recognizer?.locale.identifier ?? "en" }
    /// Its own echo at the start of a barged-in question: that many words are left out of the question.
    private var dropWords = 0

    var hearingSomething: Bool { isListening && !bargeOnly && !transcript.isEmpty }

    private var finishing = false

    /// Quiet long enough: close the audio and give the recognizer a moment (up to 0.25 s) to hand
    /// back its final result, which carries word confidences; otherwise use what it has.
    private func finish() {
        guard !finishing else { return }
        finishing = true
        request?.endAudio()
        let req = request
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.finishing, self.request === req else { return }
            self.deliver(confidence: nil, isFinal: false)
        }
    }

    private func deliver(confidence: Double?, isFinal: Bool) {
        guard isListening else { return }
        var heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if dropWords > 0 {
            heard = heard.split(separator: " ").dropFirst(dropWords).joined(separator: " ")
            dropWords = 0
        }
        let at = lastChange
        finishing = false
        stopListening()
        if heard.isEmpty { listen(); return }
        quickFailures = 0
        onQuestion?(heard, at, confidence, isFinal)
    }

    /// The recognizer ended with an error. Words already heard still count as the question. With nothing heard,
    /// a failure right after starting (the recognizer can't run at all) is retried after 1 s, 2 s, then 5 s, and
    /// after one more it stops for good and says so (11/04 review: it used to restart in a tight loop, draining the
    /// battery and saying nothing). A failure after a long listen is ordinary and restarts right away.
    func recognizerFailed() {
        let heard = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if heard, isListening { deliver(confidence: nil, isFinal: false); return }
        let quick = Date().timeIntervalSince(listenStarted) < Self.quickFailure
        stopListening()
        guard quick else { quickFailures = 0; lastRetryDelay = 0; listen(); return }
        quickFailures += 1
        guard let wait = Self.retryDelay(afterQuickFailures: quickFailures) else {
            lastRetryDelay = nil
            gaveUp = true
            onGaveUp?()
            return
        }
        lastRetryDelay = wait
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            guard let self, !Task.isCancelled, self.isRunning, !self.isListening, !self.gaveUp else { return }
            if let onRetry = self.onRetry { onRetry() } else { self.listen() }
        }
    }
}

private final class LiveTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var isSpeaking = false
    private var feeding: SFSpeechAudioBufferRecognitionRequest?
    private var ring: [AVAudioPCMBuffer] = []
    private var ringSeconds = 0.0

    func speaking(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        isSpeaking = on
    }

    func startFeeding(_ req: SFSpeechAudioBufferRecognitionRequest, replay: Bool) {
        lock.lock(); defer { lock.unlock() }
        if replay { ring.forEach(req.append) }
        ring.removeAll(); ringSeconds = 0
        feeding = req
        isSpeaking = false
    }

    func stopFeeding() { lock.lock(); feeding = nil; lock.unlock() }

    /// (barge-in now?, level in dBFS)
    func handle(_ buffer: AVAudioPCMBuffer) -> (Bool, Float) {
        let level = Self.level(buffer)
        lock.lock(); defer { lock.unlock() }
        if let feeding { feeding.append(buffer); return (false, level) }
        if let copy = Self.copy(buffer) {
            ring.append(copy)
            ringSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            while ringSeconds > 1.2, let first = ring.first {
                ringSeconds -= Double(first.frameLength) / first.format.sampleRate
                ring.removeFirst()
            }
        }
        return (false, level)   // Matt 11/6: sound alone (a cough, a murmur) never interrupts; only words do
    }

    static func level(_ b: AVAudioPCMBuffer) -> Float {
        guard let d = b.floatChannelData?[0], b.frameLength > 0 else { return -100 }
        var sum: Float = 0
        for i in 0 ..< Int(b.frameLength) { sum += d[i] * d[i] }
        let rms = (sum / Float(b.frameLength)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -100
    }

    static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength),
              let src = b.floatChannelData, let dst = out.floatChannelData else { return nil }
        out.frameLength = b.frameLength
        for c in 0 ..< Int(b.format.channelCount) { dst[c].update(from: src[c], count: Int(b.frameLength)) }
        return out
    }
}
