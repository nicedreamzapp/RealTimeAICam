// Live Cam's ears (ported from Moonstone's LiveListener, 2026-11-04): one audio engine for the whole visit,
// Apple's recognizer on the phone only (requiresOnDeviceRecognition, so it works in airplane mode), in Your
// language when the phone can recognize it offline, else English. While Live Cam speaks nothing is
// transcribed, so it never hears itself; only the loudness is watched, and a voice clearly above its
// own echo is a barge-in (the last second is kept so the first words survive).
import AVFoundation
import Foundation
import Speech

@MainActor
final class LiveListener {
    enum Failure: Error { case notAllowed, unavailable }

    /// A finished utterance: text, when its last word was heard, the recognizer's average word
    /// confidence (nil if it gave none) and whether it was the recognizer's final result.
    var onQuestion: ((String, Date, Double?, Bool) -> Void)?
    var onBargeIn: (() -> Void)?
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

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
            Task { @MainActor in
                if level > LiveListener.voiceLevel { self?.lastLoudAt = Date() }
                self?.onLevel?(level)
                if event { self?.onBargeIn?() }
            }
        }
        engine.prepare()
        do { try engine.start() } catch { node.removeTap(onBus: 0); return .unavailable }
        isRunning = true
        return nil
    }

    func shutdown() {
        stopListening()
        tap.speaking(false)
        isRunning = false
        guard !feedMode else { return }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        #if !targetEnvironment(simulator)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        #endif
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Test feed: one buffer, handled exactly like a mic buffer.
    func inject(_ buffer: AVAudioPCMBuffer) {
        let (event, level) = tap.handle(buffer)
        onLevel?(level)
        if event { onBargeIn?() }
    }

    func listen(replay: Bool = false) {
        guard isRunning, !isListening, let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true   // never the network: airplane mode works
        req.taskHint = .search
        request = req
        transcript = ""
        listenStarted = Date(); lastChange = Date(); lastLoudAt = Date()
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
                if let text, text != self.transcript {
                    if !self.finishing { self.lastChange = Date() }
                    self.transcript = text; self.onPartial?(text)
                }
                if final { self.deliver(confidence: conf, isFinal: true) } else if failed { self.deliver(confidence: nil, isFinal: false) }
            }
        }
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            while let self, self.isListening, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                let now = Date()
                let wordsQuiet = now.timeIntervalSince(self.lastChange), micQuiet = now.timeIntervalSince(self.lastLoudAt)
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
        watchdog?.cancel(); watchdog = nil
        tap.stopFeeding()
        request?.endAudio()
        task?.cancel()
        task = nil; request = nil
        isListening = false
    }

    /// While Live Cam speaks or thinks: watch for a barge-in, transcribe nothing.
    func watchForBargeIn(_ on: Bool) { tap.speaking(on) }

    var hearingSomething: Bool { isListening && !transcript.isEmpty }

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
        let heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let at = lastChange
        finishing = false
        stopListening()
        if heard.isEmpty { listen(); return }
        onQuestion?(heard, at, confidence, isFinal)
    }
}

private final class LiveTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var isSpeaking = false
    private var feeding: SFSpeechAudioBufferRecognitionRequest?
    private var barge = LiveBargeIn()
    private var ring: [AVAudioPCMBuffer] = []
    private var ringSeconds = 0.0

    func speaking(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if on, !isSpeaking { barge.reset() }
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
        guard isSpeaking else { return (false, level) }
        if barge.feed(level: level) { isSpeaking = false; return (true, level) }
        return (false, level)
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
