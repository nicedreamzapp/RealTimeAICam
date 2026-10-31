import AVFoundation
import Foundation
import Speech

/// Talk mode's ears. One audio engine runs for the whole Talk session (no
/// route switch per question, which costs hundreds of milliseconds), and the
/// microphone is used in exactly two ways:
///
/// - **Listening**: buffers go to Apple's speech recognizer, on the phone only
///   (`requiresOnDeviceRecognition`). A question ends after about 1.2 s with no
///   new word.
/// - **While the app speaks**: nothing is transcribed, so it can never hear
///   itself. Only the loudness is watched; a voice clearly louder than the
///   app's own echo, for about a quarter second, is a barge-in. The last
///   second of sound is kept, so the start of the interrupting question is
///   not lost.
///
/// No network: the recognizer is refused unless it runs on the phone.
@MainActor
final class TalkListener {
    enum Failure { case notAllowed, unavailable }

    /// A finished question, and when its last word was heard.
    var onQuestion: ((String, Date) -> Void)?
    /// The person started talking over the app.
    var onBargeIn: (() -> Void)?
    /// Partial words as they are heard (for the screen).
    var onPartial: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var lastChange = Date()
    private var listenStarted = Date()
    private var watchdog: Task<Void, Never>?
    private(set) var isRunning = false
    private(set) var isListening = false

    /// Shared with the audio thread.
    private let tapState = TapState()

    // MARK: Session

    /// Asks for the mic and speech permissions, sets up one play-and-record
    /// session and starts the engine. Does not start listening yet.
    func start() async -> Failure? {
        guard !isRunning else { return nil }
        guard await Self.authorize() else { return .notAllowed }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            return .unavailable
        }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default,
                              options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
            try s.setActive(true, options: .notifyOthersOnDeactivation)
            AudioRoute.preferLoudspeakerIfNothingConnected(s)
        } catch { return .unavailable }

        let node = engine.inputNode
        // Echo cancellation: the phone's own voice processing takes most of
        // the app's speech out of the mic signal, which is what lets a barge-in
        // be heard over it. Ducking of the app's own playback is kept minimal.
        #if !targetEnvironment(simulator)
        if (try? node.setVoiceProcessingEnabled(true)) != nil {
            node.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        #endif
        node.removeTap(onBus: 0)
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return .unavailable }
        let state = tapState
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            switch state.handle(buffer) {
            case .none: break
            case .bargeIn:
                Task { @MainActor in self?.onBargeIn?() }
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            node.removeTap(onBus: 0)
            return .unavailable
        }
        isRunning = true
        return nil
    }

    /// Everything off and the audio handed back to plain playback.
    func shutdown() {
        stopListening()
        tapState.set(mode: .idle)
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        #if !targetEnvironment(simulator)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        #endif
        isRunning = false
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? s.setActive(true)
        AudioRoute.preferLoudspeakerIfNothingConnected(s)
    }

    // MARK: Listening

    /// Open the recognizer. `replay` feeds the last second of sound first
    /// (after a barge-in, so the first words are kept).
    func listen(replay: Bool = false) {
        guard isRunning, !isListening, let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.taskHint = .search
        request = req
        transcript = ""
        listenStarted = Date()
        lastChange = Date()
        isListening = true
        tapState.startFeeding(req, replay: replay)
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.isListening, self.request === req else { return }
                if let text, text != self.transcript {
                    self.transcript = text
                    self.lastChange = Date()
                    self.onPartial?(text)
                }
                if final || failed { self.finishQuestion(restartIfEmpty: true) }
            }
        }
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            while let self, self.isListening, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let now = Date()
                if TalkTiming.questionEnded(heardSomething: !self.transcript.isEmpty,
                                            quiet: now.timeIntervalSince(self.lastChange)) {
                    self.finishQuestion(restartIfEmpty: true)
                } else if self.transcript.isEmpty, now.timeIntervalSince(self.listenStarted) > TalkTiming.idleRestart {
                    // Nothing said for a while: a fresh task, still listening.
                    self.stopListening()
                    self.listen()
                }
            }
        }
    }

    /// Close the recognizer without delivering anything.
    func stopListening() {
        watchdog?.cancel(); watchdog = nil
        tapState.stopFeeding()
        request?.endAudio()
        task?.cancel()
        task = nil; request = nil
        isListening = false
    }

    /// Watch for a barge-in while the app is speaking (mic never transcribed).
    func watchWhileSpeaking(_ on: Bool) {
        tapState.set(mode: on ? .speaking : .idle)
    }

    private func finishQuestion(restartIfEmpty: Bool) {
        let heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let at = lastChange
        stopListening()
        if heard.isEmpty || TalkRouting.isEcho(heard) {
            if restartIfEmpty { listen() }
            return
        }
        onQuestion?(heard, at)
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
    }
}

/// What the audio thread does with each buffer. Locked, tiny, no allocation
/// beyond the one-second replay ring.
private final class TapState: @unchecked Sendable {
    enum Mode { case idle, speaking }
    enum Event { case none, bargeIn }

    private let lock = NSLock()
    private var mode: Mode = .idle
    private var feeding: SFSpeechAudioBufferRecognitionRequest?
    private var bargeIn = TalkBargeIn()
    private var ring: [AVAudioPCMBuffer] = []
    private static let ringBuffers = 48 // about a second at 1024 frames, 48 kHz

    func set(mode new: Mode) {
        lock.lock(); defer { lock.unlock() }
        if new == .speaking, mode != .speaking { bargeIn.reset() }
        mode = new
    }

    func startFeeding(_ req: SFSpeechAudioBufferRecognitionRequest, replay: Bool) {
        lock.lock(); defer { lock.unlock() }
        if replay { ring.forEach(req.append) }
        ring.removeAll()
        feeding = req
        mode = .idle
    }

    func stopFeeding() {
        lock.lock(); defer { lock.unlock() }
        feeding = nil
    }

    func handle(_ buffer: AVAudioPCMBuffer) -> Event {
        lock.lock(); defer { lock.unlock() }
        if let feeding {
            feeding.append(buffer)
            return .none
        }
        // Keep a copy for the replay ring: the engine reuses its buffers.
        if let copy = Self.copy(buffer) {
            ring.append(copy)
            if ring.count > Self.ringBuffers { ring.removeFirst(ring.count - Self.ringBuffers) }
        }
        guard mode == .speaking else { return .none }
        if bargeIn.feed(level: Self.level(buffer)) {
            mode = .idle
            return .bargeIn
        }
        return .none
    }

    /// RMS level of the first channel, in dBFS.
    static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -100 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0 ..< n { sum += data[i] * data[i] }
        let rms = (sum / Float(n)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -100
    }

    static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        out.frameLength = b.frameLength
        let channels = Int(b.format.channelCount)
        if let src = b.floatChannelData, let dst = out.floatChannelData {
            for c in 0 ..< channels { dst[c].update(from: src[c], count: Int(b.frameLength)) }
            return out
        }
        return nil
    }
}
