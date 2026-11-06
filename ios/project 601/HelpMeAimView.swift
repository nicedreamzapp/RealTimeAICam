import AVFoundation
import CoreImage
import Combine
import ImageIO
import Photos
import Speech
import SwiftUI
import UIKit

// MARK: - Help Me Aim: screen
//
// "You tell the camera what you want, and it talks you into the shot."
// Asked for by Dennis Long (Pixel Guided Frame) and Amrit; the AppleVis
// testers' complaints about other camera apps set the rules here: the
// countdown is spoken once, the app never talks on top of VoiceOver's own
// voice, and guidance picks back up after leaving the app and returning.

// MARK: Voice

/// One voice at a time. With "let VoiceOver do the talking" (the
/// speakAnswersAloud setting turned off) and VoiceOver running, every line
/// goes to VoiceOver as an announcement and the app's own voice stays silent;
/// otherwise the app speaks and posts nothing. Never both, which is how other
/// apps end up saying the countdown twice.
@MainActor
final class AimVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var announcementPending = false
    private var token = 0
    /// Runs once when the current line has fully finished (not when it is
    /// cut off by a newer line).
    private var finished: (() -> Void)?
    private var current: AVSpeechUtterance?
    var voiceIdentifier: String = ""

    override init() {
        super.init()
        synth.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(announcementFinished),
            name: UIAccessibility.announcementDidFinishNotification, object: nil)
    }

    private var usesVoiceOver: Bool {
        let speaksAloud = UserDefaults.standard.object(forKey: "speakAnswersAloud") as? Bool ?? true
        return !speaksAloud && UIAccessibility.isVoiceOverRunning
    }

    var isBusy: Bool { synth.isSpeaking || announcementPending || translatingLine }
    /// A line is being put into Your language (2026-11-04); counts as busy.
    private var translatingLine = false

    func warmRoute() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audio.setActive(true)
        AudioRoute.preferLoudspeakerIfNothingConnected(audio)
    }

    func say(_ text: String, then done: (() -> Void)? = nil) {
        // The app's lines are already in the app's language (L()). A Spanish
        // app says them from the bundled Spanish in a Spanish voice: no
        // translator, nothing to download (2026-11-05).
        // Your language (French...): every guidance line and the description are
        // translated first (cached, so repeated lines are instant). English: no change.
        if case let .asIs(lang) = AimLineRoute.pick(appLang: AppLang.code, yourLanguage: YourLanguage.activeCode) {
            speakLine(text, language: lang, then: done)
            return
        }
        token += 1
        let mine = token
        finished = done
        translatingLine = true
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        Task { @MainActor [weak self] in
            let out = await YourLanguage.intoActive(AimPhrases.capitalized(text))
            guard let self, token == mine else { return }
            translatingLine = false
            speakLine(out.text, language: out.lang, then: done)
        }
    }

    /// Lines already in their language, said one after the other: in a Spanish
    /// app the photo's description (content, in Your language) and then the
    /// app's own "saved to your photos" in Spanish, each in its own voice.
    func say(parts: [(text: String, lang: String)], then done: (() -> Void)? = nil) {
        guard let first = parts.first else { done?(); return }
        let rest = Array(parts.dropFirst())
        speakLine(first.text, language: first.lang) { [weak self] in
            guard let self else { return }
            if rest.isEmpty { done?() } else { say(parts: rest, then: done) }
        }
    }

    private func speakLine(_ text: String, language: String, then done: (() -> Void)?) {
        translatingLine = false
        let line = SpeakableText.spoken(AimPhrases.capitalized(text), lang: language)
        AimDevLog.note((usesVoiceOver ? "SAY(voiceover) " : "SAY ") + line)
        #if DEBUG
        if language != YourLanguageRules.english { SpeakLog.note("aim[\(language)]", line) }
        #endif
        token += 1
        let mine = token
        finished = done
        if usesVoiceOver {
            if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
            announcementPending = true
            // Tagged with its language so VoiceOver reads Spanish in Spanish.
            UIAccessibility.post(notification: .announcement,
                                 argument: SpeechManager.voiceOverLine(line, lang: language))
            // If VoiceOver drops the announcement it never reports back;
            // allow roughly the time it takes to say the line.
            let limit = max(2.5, Double(line.count) * 0.08)
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
                guard let self, token == mine else { return }
                complete()
            }
            return
        }
        announcementPending = false
        let prepared = YourLanguageVoice.prepare(line, lang: language, selected: voiceIdentifier)
        let utterance = AVSpeechUtterance(string: prepared.text)
        utterance.voice = prepared.voice
            ?? AVSpeechSynthesisVoice(language: language == YourLanguageRules.english ? "en-US" : language)
        utterance.rate = 0.52
        utterance.volume = 1.0
        #if DEBUG
        if AimFake.word != nil { utterance.volume = 0 } // silent phone test, the log has every line
        #endif
        current = utterance
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        synth.speak(utterance)
    }

    func stop() {
        finished = nil
        translatingLine = false
        token += 1
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        announcementPending = false
    }

    private func complete() {
        announcementPending = false
        let done = finished
        finished = nil
        done?()
    }

    @objc private func announcementFinished() {
        guard announcementPending else { return }
        token += 1
        complete()
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current, ObjectIdentifier(current) == id else { return }
            self.current = nil
            complete()
        }
    }
}

// MARK: Dev speech log

/// DEV-INSTALL AID ONLY: with HELP_ME_AIM_SHOT_LOG on the xcodebuild command
/// line, every line the app says (and listening events) is appended with a
/// timestamp to Documents/HelpMeAimShots/speech-log.txt so field runs can be
/// checked afterwards. Without the flag this does nothing.
enum AimDevLog {
    #if HELP_ME_AIM_SHOT_LOG
    private static let queue = DispatchQueue(label: "aim.devlog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    #endif

    static func note(_ text: String) {
        #if HELP_ME_AIM_SHOT_LOG
        let line = "\(formatter.string(from: Date()))  \(text)\n"
        queue.async {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let dir = docs.appendingPathComponent("HelpMeAimShots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("speech-log.txt")
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
        #endif
    }
}

// MARK: Tones

@MainActor
final class AimTonePlayer {
    static let shared = AimTonePlayer()
    private var player: AVAudioPlayer?
    private let startData = AimTones.wav(AimTones.start)
    private let endData = AimTones.wav(AimTones.end)

    /// Plays on whatever route the session has now (speaker is forced).
    func play(start: Bool) {
        player?.stop()
        player = try? AVAudioPlayer(data: start ? startData : endData)
        player?.volume = 1.0
        player?.prepareToPlay()
        player?.play()
    }
}

// MARK: Listening for the word

/// Hears one word or short phrase, on the phone only. Beeps, listens by
/// itself, stops after a short silence, beeps again. Nothing to hold.
@MainActor
final class AimWordListener: ObservableObject {
    enum Outcome { case result(AimListening.Result), notAllowed, unavailable }

    @Published private(set) var isRunning = false
    @Published private(set) var transcript = ""

    /// Your language when the phone can listen to it offline, else English.
    private var recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastChange = Date()
    private var startedAt = Date()
    private var failed = false
    private var watchdog: Task<Void, Never>?
    private var finish: ((Outcome) -> Void)?
    private var starting = false

    func start(_ done: @escaping (Outcome) -> Void) async {
        guard !isRunning, !starting else { return }
        starting = true
        defer { starting = false }
        guard await Self.authorize() else { done(.notAllowed); return }
        recognizer = YourLanguageVoice.recognizer()
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            done(.unavailable); return
        }
        // Record and play on one session: the beep must be heard on the
        // loudspeaker and the mic must be live, VoiceOver on or off.
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default,
                              options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
            try s.setActive(true, options: .notifyOthersOnDeactivation)
            AudioRoute.preferLoudspeakerIfNothingConnected(s)
        } catch { done(.unavailable); return }

        AimTonePlayer.shared.play(start: true)
        AimDevLog.note("[beep start]")
        try? await Task.sleep(nanoseconds: UInt64((AimTones.duration + 0.08) * 1_000_000_000))

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Offline only: the word never leaves the phone.
        req.requiresOnDeviceRecognition = true
        req.contextualStrings = ["keys", "wallet", "phone", "cup", "dog", "cat", "painting", "remote", "glasses", "door"]
        request = req
        transcript = ""
        failed = false
        finish = done
        let node = engine.inputNode
        node.removeTap(onBus: 0)
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { cleanup(); done(.unavailable); return }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buf, _ in
            req?.append(buf)
        }
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let bad = error != nil
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                if let text, text != self.transcript {
                    self.transcript = text
                    self.lastChange = Date()
                }
                if bad { self.failed = true }
                if final || bad { self.stop(deliver: true) }
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            cleanup()
            finish = nil
            done(.unavailable)
            return
        }
        isRunning = true
        AimDevLog.note("[listening]")
        startedAt = Date()
        lastChange = Date()
        watchdog = Task { @MainActor [weak self] in
            while let self, self.isRunning {
                try? await Task.sleep(nanoseconds: 150_000_000)
                let now = Date()
                if AimListening.shouldStop(heardSomething: !self.transcript.isEmpty,
                                           quiet: now.timeIntervalSince(self.lastChange),
                                           total: now.timeIntervalSince(self.startedAt)) {
                    self.stop(deliver: true)
                }
            }
        }
    }

    /// Stop listening. `deliver` false means the result is thrown away
    /// (leaving the screen); otherwise the end beep plays first.
    func stop(deliver: Bool) {
        guard isRunning else { return }
        isRunning = false
        let result = AimListening.result(transcript: transcript, failed: failed)
        let done = finish
        finish = nil
        cleanup()
        AimDevLog.note("[listen end] \(result) deliver=\(deliver)")
        guard deliver else { return }
        AimTonePlayer.shared.play(start: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + AimTones.duration + 0.1) {
            done?(.result(result))
        }
    }

    private func cleanup() {
        watchdog?.cancel(); watchdog = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel(); task = nil; request = nil
        // Hand the audio back to plain playback for the steering voice.
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? s.setActive(true)
        // Loudspeaker only when nothing is connected. Forcing it here pulled
        // Help Me Aim off Dennis's Bluetooth headset (email, 2026-09-20); the
        // 9/19 AirPods fix covered every other screen but missed this one.
        AudioRoute.preferLoudspeakerIfNothingConnected(s)
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

#if DEBUG
/// Test builds only: `-aimFakeFind <word>` opens Help Me Aim, asks for the
/// word, and feeds Documents/photo-test/flow/*.jpg in order as the camera,
/// one photo per look (the last one repeats). Lets a phone walk the whole
/// describing-model flow without anyone aiming it (2026-11-03).
@MainActor
enum AimFake {
    static let word: String? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-aimFakeFind"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()

    private static let frames: [Data] = {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        let dir = docs.appendingPathComponent("photo-test/flow", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.compactMap { try? Data(contentsOf: $0) }
    }()

    private static var shown = 0

    static func nextFrame() -> Data? {
        guard !frames.isEmpty else { return nil }
        defer { shown += 1 }
        return frames[min(shown, frames.count - 1)]
    }

    static var lastFrame: Data? {
        frames.isEmpty ? nil : frames[min(max(shown - 1, 0), frames.count - 1)]
    }
}
#endif

// MARK: Controller

@MainActor
final class HelpMeAimController: ObservableObject {
    enum Phase: Equatable { case choosing, asking, aiming, capturing, taken }

    @Published private(set) var phase: Phase = .choosing
    @Published private(set) var subject: AimSubject?
    @Published private(set) var statusText = ""
    @Published private(set) var countdownWord: String?
    @Published private(set) var lastPhoto: UIImage?
    @Published private(set) var loadingModel = false
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    @Published private(set) var torchOn = false
    /// Words that found something before; buttons on the Something Else screen.
    @Published private(set) var recentTargets: [String] = AimRecentTargets.all()
    /// What the person asked for this time, kept until the photo is saved.
    private var askedWord: String?

    let voice = AimVoice()
    let listener = AimWordListener()
    let analyzer = AimFrameAnalyzer()
    weak var camera: AimCameraView?

    private var coach: AimCoach?
    /// Other things YOLOE saw in the last few frames.
    private var recentOthers: [[AimElsewhere.Seen]] = []
    private var countdownTask: Task<Void, Never>?
    private var lookTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var classNames: [String]?
    private var classIndex: [String: [Int32]] = [:]
    private var finder: AimObjectFinder?
    private var paused = false
    /// The camera view asks this before (re)starting on a SwiftUI refresh.
    var isPaused: Bool { paused }
    private let tick = UIImpactFeedbackGenerator(style: .light)
    private let beat = UIImpactFeedbackGenerator(style: .medium)
    private let notify = UINotificationFeedbackGenerator()

    init() {
        analyzer.onObservation = { [weak self] obs in
            MainActor.assumeIsolated { self?.handle(obs) }
        }
        #if DEBUG
        // Test builds only: open on Picture Taken with a long description, so
        // the simulator can check it scrolls without a camera.
        if ProcessInfo.processInfo.arguments.contains("-aimPreviewTaken") {
            lastPhoto = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900)).image { ctx in
                UIColor.darkGray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
            }
            statusText = Array(repeating: "A soft white stuffed bunny with long floppy ears sits on a wooden table next to a blue mug, a pair of glasses and a stack of mail.", count: 5).joined(separator: " ") + " END OF DESCRIPTION. Saved to your photos with its description."
            phase = .taken
        }
        #endif
    }

    func setVoice(_ identifier: String) {
        voice.voiceIdentifier = identifier
    }

    // MARK: Choices

    func chooseFace() { askedWord = nil; begin(.face) }
    func choosePage() { askedWord = nil; begin(.page) }

    func chooseSomethingElse() {
        isTyping = false
        phase = .asking
        statusText = L("What are you looking for?")
        voice.warmRoute()
        // Ask, wait for the sentence to finish completely, then beep and
        // listen on our own. Nothing to press or hold (Matt, 2026-09-16).
        let ask = { [weak self] in
            guard let self else { return }
            voice.say(AimPhrases.askWhat) { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + AimListening.afterPrompt) {
                    guard let self, self.phase == .asking, !self.paused, !self.isTyping,
                          !self.listener.isRunning else { return }
                    self.listen()
                }
            }
        }
        if UIAccessibility.isVoiceOverRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, phase == .asking, !paused, !isTyping else { return }
                ask()
            }
        } else {
            ask()
        }
    }

    /// The person went for the text field instead: stop asking and don't
    /// open the mic ("After the beep…" used to play over the typing).
    private var isTyping = false
    func typingStarted() {
        guard phase == .asking else { return }
        AimDevLog.note("[typing]")
        isTyping = true
        voice.stop()
        if listener.isRunning { listener.stop(deliver: false) }
    }

    func backToChoices() {
        stopAiming()
        listener.stop(deliver: false)
        phase = .choosing
        statusText = ""
        subject = nil
    }

    func listen() {
        isTyping = false
        if listener.isRunning {
            listener.stop(deliver: true)
            return
        }
        voice.stop()
        tick.impactOccurred()
        let listener = listener
        let handle: (AimWordListener.Outcome) -> Void = { [weak self] outcome in
            guard let self, phase == .asking else { return }
            switch outcome {
            case let .result(.heard(text)):
                submit(text)
            case let .result(other):
                if let line = AimListening.reply(for: other) {
                    statusText = AimPhrases.capitalized(line)
                    voice.say(line)
                }
            case .notAllowed:
                voice.say(L("I can't use the microphone. Allow it in Settings, or type the word."))
            case .unavailable:
                voice.say(L("Offline listening isn't available on this phone. Type the word instead."))
            }
        }
        Task { await listener.start(handle) }
    }

    func submit(_ text: String) {
        // Typed while the mic was open: close it now, or it hears the app's
        // own "Looking for…" line (seen in the 2026-09-16 live runs).
        if listener.isRunning { listener.stop(deliver: false) }
        AimNames.forgetAll()
        // Said or typed in Your language ("taza"): into English first, the word
        // matching below stays English (2026-11-04).
        if YourLanguage.activeCode != YourLanguageRules.english {
            // The person's own words: what the recent buttons keep, and in a
            // Spanish app the name said inside the lines ("mis llaves").
            let own = YourLanguage.activeCode == AppLang.spanish ? AimNames.spanishPhrase(text)
                : text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            Task { @MainActor [weak self] in
                let english = await AimLanguage.wordForMatching(text)
                AimDevLog.note("YOUR LANGUAGE \(text) -> \(english)")
                #if DEBUG
                SpeakLog.note("aimWord[\(YourLanguage.activeCode)>en]", "\(text) -> \(english)")
                #endif
                self?.submitEnglish(english, own: own.isEmpty ? nil : own)
            }
            return
        }
        submitEnglish(text, own: nil)
    }

    /// `own`: the words as the person said them in Your language, when it isn't English.
    private func submitEnglish(_ text: String, own: String?) {
        let names = vocabulary()
        let said = AimVocabulary.normalize(text)
        if let own, AppLang.isSpanish, YourLanguage.activeCode == AppLang.spanish, !said.isEmpty {
            AimNames.setSpanish(said, own)
        }
        guard let match = AimVocabulary.match(text, index: classIndex), !names.isEmpty else {
            // No name for it in the finder: the describing model looks instead.
            if !said.isEmpty, OnDeviceVisionNarrator.isBundled {
                askedWord = own ?? said
                begin(.described(said))
                return
            }
            statusText = AimPhrases.capitalized(AimPhrases.cantLookFor(said))
            voice.say(AimPhrases.cantLookFor(said))
            return
        }
        if let own, AppLang.isSpanish, YourLanguage.activeCode == AppLang.spanish {
            AimNames.setSpanish(match.spokenName, own)
        }
        askedWord = own ?? said
        begin(.object(match))
    }

    func clearRecentTargets() {
        AimRecentTargets.clear()
        recentTargets = []
    }

    private func vocabulary() -> [String] {
        if let classNames { return classNames }
        let names = AimObjectFinder.loadClassNames()
        classNames = names
        classIndex = AimVocabulary.index(names)
        return names
    }

    // MARK: Aiming

    private var diagTimer: Timer?

    /// DEV: once a second, what the analyser and camera are doing.
    private func startDiagnostics() {
        #if HELP_ME_AIM_SHOT_LOG
        diagTimer?.invalidate()
        diagTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let st = self.analyzer.snapshotStats()
                AimDevLog.note("[diag] phase=\(self.phase) ctlPaused=\(self.paused) kind=\(st.kind) anPaused=\(st.paused) "
                    + "offered=\(st.offered) analyzed=\(st.analyzed) buf=\(Int(st.bufferSize.width))x\(Int(st.bufferSize.height)) "
                    + "turns=\(st.quarterTurns) camPos=\(self.cameraPosition == .front ? "front" : "back") "
                    + "\(self.camera?.debugInfo() ?? "no camera view") last: \(st.lastSummary)")
            }
        }
        #endif
    }

    private func begin(_ newSubject: AimSubject) {
        AimDevLog.note("[aim] \(newSubject.spokenName)")
        startDiagnostics()
        subject = newSubject
        phase = .aiming
        paused = false
        coach = AimCoach(subject: newSubject)
        coach?.reset(now: Date())
        recentOthers = []
        switch newSubject {
        case let .object(m): AimNames.learn([m.spokenName])
        case let .described(w): AimNames.learn([w])
        default: break
        }
        statusText = L("Looking for %@", newSubject.lineName)
        if newSubject != .face { cameraPosition = .back }
        voice.warmRoute()
        if case let .described(word) = newSubject {
            sayAfterVoiceOver(AimAsk.intro(for: word))
        } else {
            sayAfterVoiceOver(AimPhrases.intro(for: newSubject))
        }
        tick.prepare(); beat.prepare(); notify.prepare()

        switch newSubject {
        case .face:
            analyzer.configure(kind: .face, classIDs: [], finder: nil)
            analyzer.setPaused(false)
        case .page:
            _ = vocabulary()
            let ids = Set(AimFrameAnalyzer.pageClassNames.flatMap { classIndex[$0] ?? [] })
            // Rectangles work right away; the model joins when it has loaded.
            analyzer.configure(kind: .page, classIDs: ids, finder: finder)
            analyzer.setPaused(false)
            loadFinder { [weak self] finder in
                self?.analyzer.configure(kind: .page, classIDs: ids, finder: finder)
            }
        case let .object(match):
            analyzer.setPaused(true)
            loadFinder { [weak self] finder in
                guard let self else { return }
                guard let finder else {
                    voice.say(L("The object finder didn't load. Try Face or Picture or Page."))
                    return
                }
                analyzer.configure(kind: .object, classIDs: Set(match.classIDs), finder: finder)
                coach?.reset(now: Date())
                if !paused { analyzer.setPaused(false) }
            }
        case let .described(word):
            analyzer.setPaused(true)
            startLooking(for: word, firstWait: 4)
        }
    }

    /// The describing model looks at one frame every few seconds and steers
    /// toward the thing; a "yes, in the middle" takes the picture.
    private func startLooking(for word: String, firstWait: Double) {
        lookTask?.cancel()
        lookTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(firstWait * 1_000_000_000))
            var misses = 0
            var steers = 0
            var sure: Bool?
            while !Task.isCancelled, misses < AimAsk.maxMisses {
                guard let self else { return }
                guard phase == .aiming, !paused else { return }
                guard let shot = await grabFrame() else { misses += 1; continue }
                let answer = await OnDeviceVisionNarrator.shared.ask(AimAsk.question(for: word), about: shot)
                guard !Task.isCancelled, phase == .aiming, !paused else { return }
                let reading = AimAsk.read(answer)
                AimDevLog.note("[ask] \(word) -> \(answer ?? "nil")")
                if reading.found {
                    misses = 0
                    if sure == nil {
                        let listing = await OnDeviceVisionNarrator.shared.ask(AimAsk.confirmQuestion, about: shot)
                        guard !Task.isCancelled, phase == .aiming, !paused else { return }
                        sure = AimAsk.confirms(word, in: listing)
                        AimDevLog.note("[ask] confirm \(word) sure=\(sure!) -> \(listing ?? "nil")")
                    }
                    if reading.place == .middle || reading.place == nil || steers >= AimAsk.maxSteers {
                        notify.notificationOccurred(.success)
                        let line = sure == true ? AimAsk.found : AimAsk.foundUnsure
                        statusText = line
                        await speakAndWait(line)
                        guard !Task.isCancelled, phase == .aiming, !paused else { return }
                        capture()
                        return
                    }
                    steers += 1
                    tick.impactOccurred()
                    let line = AimAsk.steer(reading.place!)
                    statusText = line
                    await speakAndWait(line)
                } else {
                    misses += 1
                    if let line = AimAsk.notYet(word, misses: misses) {
                        statusText = AimPhrases.capitalized(line)
                        await speakAndWait(line)
                    }
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
            guard let self, !Task.isCancelled, phase == .aiming else { return }
            let line = AimAsk.gaveUp(word)
            statusText = line
            notify.notificationOccurred(.warning)
            voice.say(line)
        }
    }

    /// Says the line and waits (up to ~8 s) until it has been spoken, so the
    /// next frame isn't taken while the person is still listening.
    private func speakAndWait(_ line: String) async {
        voice.say(line)
        try? await Task.sleep(nanoseconds: 300_000_000)
        for _ in 0 ..< 80 where voice.isBusy {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// One still from the live camera, upright, for the describing model.
    private func grabFrame() async -> UIImage? {
        #if DEBUG
        if AimFake.word != nil { return AimFake.nextFrame().flatMap { UIImage(data: $0) } }
        #endif
        guard let camera else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            camera.captureBurst(count: 1, interval: 0) { frames in
                cont.resume(returning: frames.first.flatMap { UIImage(data: $0) })
            }
        }
    }

    private func loadFinder(_ then: @escaping (AimObjectFinder?) -> Void) {
        if let finder { then(finder); return }
        loadingModel = true
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { AimObjectFinder() }.value
            guard let self, !Task.isCancelled else { return }
            loadingModel = false
            finder = loaded
            guard phase == .aiming || phase == .capturing else { return }
            then(loaded)
        }
    }

    /// Give VoiceOver a moment to finish saying where we landed, so the
    /// first line isn't spoken on top of it.
    private func sayAfterVoiceOver(_ text: String) {
        if UIAccessibility.isVoiceOverRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, !paused else { return }
                voice.say(text)
            }
        } else {
            voice.say(text)
        }
    }

    private func handle(_ observation: AimObservation) {
        guard phase == .aiming, !paused, var coach, let subject else { return }
        var elsewhere: String?
        if let others = observation.others {
            recentOthers.append(others)
            if recentOthers.count > AimElsewhere.window { recentOthers.removeFirst() }
            let things = AimElsewhere.pick(recentOthers, excluding: AimElsewhere.targetNames(for: subject))
            AimNames.learn(things)
            elsewhere = AimElsewhere.sentence(subject: subject, things: things)
        }
        let actions = coach.observe(box: observation.box, faceCount: observation.count,
                                    now: Date(), voiceBusy: voice.isBusy, elsewhere: elsewhere)
        self.coach = coach
        for action in actions {
            switch action {
            case let .say(text, haptic):
                statusText = AimPhrases.capitalized(text)
                voice.say(text)
                switch haptic {
                case .tick: tick.impactOccurred()
                case .success: notify.notificationOccurred(.success)
                case .warning: notify.notificationOccurred(.warning)
                case .none: break
                }
            case .startCountdown:
                startCountdown()
            case .cancelCountdown:
                countdownTask?.cancel()
                countdownTask = nil
                countdownWord = nil
            }
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            for word in AimPhrases.countdown {
                guard let self, !Task.isCancelled else { return }
                countdownWord = word
                statusText = word
                voice.say(word)
                beat.impactOccurred()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            countdownWord = nil
            capture()
        }
    }

    /// Double tap anywhere (or the magic tap): shoot now.
    func shootNow() {
        guard phase == .aiming else { return }
        capture()
    }

    private func capture() {
        guard phase == .aiming, let camera, let subject else { return }
        countdownTask?.cancel(); countdownTask = nil
        countdownWord = nil
        analyzer.setPaused(true)
        phase = .capturing
        statusText = L("Taking the picture")
        // Nothing for the object finder to score when the describing model
        // found it: keep the sharpest frame of the burst.
        let snapshot: (kind: AimFrameAnalyzer.Kind, ids: Set<Int32>, finder: AimObjectFinder?)?
        if case .described = subject { snapshot = nil } else { snapshot = analyzer.snapshot() }
        let framing = subject.framing
        let subjectName = subject.spokenName
        let isPage = subject == .page
        burst(camera) { [weak self] frames in
            guard let self, phase == .capturing else { return }
            guard !frames.isEmpty else {
                voice.say(AimPhrases.captureFailed)
                statusText = AimPhrases.capitalized(AimPhrases.captureFailed)
                phase = .aiming
                coach?.reset(now: Date())
                analyzer.setPaused(false)
                return
            }
            setTorch(false)
            notify.notificationOccurred(.success)
            statusText = L("Picking the best one")
            Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    AimShotProcessor.process(frames, snapshot: snapshot, framing: framing, subjectName: subjectName)
                }.value
                guard let self, phase == .capturing else { return }
                lastPhoto = result.image
                phase = .taken
                statusText = L("Picture taken")
                #if HELP_ME_AIM_SHOT_LOG
                if let keep = result.keep { TestShotLog.write(keep) }
                #endif
                AimDevLog.note("[shot] winner=\(result.keep?.info.winner ?? -1) cropped=\(result.keep?.cropped ?? false)")
                // Exactly one photo per burst reaches the library.
                guard let jpeg = result.keep?.photo else {
                    voice.say(AimPhrases.captureFailed)
                    statusText = AimPhrases.capitalized(AimPhrases.captureFailed)
                    return
                }
                // The photo is saved with its description written into it
                // (AppleVis user "Matt", 2026-09-15). No model on the phone,
                // or nothing to say: the plain photo, as before.
                var description: String?
                if OnDeviceVisionNarrator.isBundled, let shot = result.image {
                    statusText = AimPhrases.describing
                    voice.say(AimPhrases.describing)
                    description = await AimCaption.describe(shot, isPage: isPage)
                }
                let toSave = description.flatMap { AimCaption.embed($0, in: jpeg) } ?? jpeg
                if toSave == jpeg { description = nil }
                Self.save(toSave) { [weak self] saved in
                    // Taking another or leaving must not be talked over.
                    guard let self, phase == .taken else { return }
                    if saved, subject.remembersWord, let word = askedWord {
                        AimRecentTargets.remember(word)
                        recentTargets = AimRecentTargets.all()
                    }
                    // A description heard to the end is a success (rating prompt).
                    let described = description != nil
                    let spoken = { if described { RatePrompt.resultSpoken(viaVoiceOver: false) } }
                    guard let description else {
                        let line = AimPhrases.capitalized(AimPhrases.taken(saved: saved))
                        statusText = line
                        voice.say(line, then: spoken)
                        return
                    }
                    let after = AimPhrases.capitalized(
                        saved ? AimPhrases.savedWithDescription : AimPhrases.notSavedWithDescription) + "."
                    guard AppLang.isSpanish else {
                        let line = description + " " + after
                        statusText = line
                        voice.say(line, then: spoken)
                        return
                    }
                    // Spanish app: the description is content (Your language's
                    // translator, as on every other screen), the line after it
                    // is the app's own Spanish; each said in its own voice.
                    Task { @MainActor [weak self] in
                        let out = await YourLanguage.intoActive(description)
                        guard let self, phase == .taken else { return }
                        statusText = out.text + " " + after
                        voice.say(parts: [(out.text, out.lang), (after, AppLang.spanish)], then: spoken)
                    }
                }
            }
        }
    }

    private func burst(_ camera: AimCameraView, completion: @escaping ([Data]) -> Void) {
        #if DEBUG
        if AimFake.word != nil {
            let frames = AimFake.lastFrame.map { [$0] } ?? []
            DispatchQueue.main.async { completion(frames) }
            return
        }
        #endif
        camera.captureBurst(count: Self.burstCount, interval: Self.burstInterval, completion: completion)
    }

    static let burstCount = 5
    static let burstInterval: TimeInterval = 0.18

    func takeAnother() {
        guard let subject else { backToChoices(); return }
        lastPhoto = nil
        begin(subject)
    }

    private static func save(_ data: Data, done: @escaping @MainActor (Bool) -> Void) {
        #if DEBUG
        // The fake-camera test never puts its stock photos in the library.
        if AimFake.word != nil { Task { @MainActor in done(true) }; return }
        #endif
        AimCaption.saveToPhotos(data, done: done)
    }

    // MARK: Camera controls

    func toggleCamera() {
        cameraPosition = cameraPosition == .back ? .front : .back
        setTorch(false)
        coach?.reset(now: Date())
        voice.say(cameraPosition == .front ? L("front camera") : L("back camera"))
    }

    func toggleTorch() {
        setTorch(!torchOn)
        voice.say(torchOn ? L("Flashlight, on") : L("Flashlight, off"))
    }

    private func setTorch(_ on: Bool) {
        let allowed = on && cameraPosition == .back
        camera?.setTorch(allowed)
        torchOn = allowed
    }

    // MARK: Lifecycle

    private func stopAiming() {
        lookTask?.cancel(); lookTask = nil
        countdownTask?.cancel(); countdownTask = nil
        countdownWord = nil
        analyzer.setPaused(true)
        setTorch(false)
        voice.stop()
    }

    /// Leaving for the background (or Control Center): torch off, camera
    /// off, countdown cancelled. The screen and the subject are kept.
    func pause() {
        AimDevLog.note("[pause] phase=\(phase)")
        paused = true
        stopAiming()
        listener.stop(deliver: false)
        camera?.stop()
        if phase == .capturing { phase = .aiming }
    }

    /// Back in the app: pick the steering up where it was.
    func resume() {
        guard paused else { return }
        AimDevLog.note("[resume] phase=\(phase)")
        paused = false
        guard phase == .aiming, let subject else { return }
        camera?.start(position: cameraPosition)
        coach?.reset(now: Date())
        voice.warmRoute()
        sayAfterVoiceOver(L("Still looking for %@", subject.lineName))
        switch subject {
        case .object: if finder != nil { analyzer.setPaused(false) }
        case let .described(word): startLooking(for: word, firstWait: 2)
        default: analyzer.setPaused(false)
        }
    }

    /// Leaving the screen: everything off and the model released.
    func shutdown() {
        diagTimer?.invalidate(); diagTimer = nil
        paused = true
        stopAiming()
        loadTask?.cancel(); loadTask = nil
        listener.stop(deliver: false)
        camera?.stop()
        analyzer.unload()
        finder = nil
        coach = nil
    }
}

// MARK: Camera representable

struct AimCameraPreview: UIViewRepresentable {
    @ObservedObject var controller: HelpMeAimController

    func makeUIView(context _: Context) -> AimCameraView {
        let view = AimCameraView()
        let analyzer = controller.analyzer
        view.onFrame = { buffer, turns in analyzer.offer(buffer, quarterTurns: turns) }
        controller.camera = view
        view.start(position: controller.cameraPosition)
        return view
    }

    func updateUIView(_ view: AimCameraView, context _: Context) {
        // Every SwiftUI refresh lands here (a status line changing is
        // enough). Never restart a camera the controller paused for the
        // background or Control Center; resume() starts it again.
        guard !controller.isPaused else { return }
        view.start(position: controller.cameraPosition)
    }

    static func dismantleUIView(_ view: AimCameraView, coordinator _: ()) {
        view.setTorch(false)
        view.stop()
    }
}

// MARK: Screen

struct HelpMeAimView: View {
    let voiceIdentifier: String
    let onBack: () -> Void

    @StateObject private var controller = HelpMeAimController()
    @Environment(\.scenePhase) private var scenePhase
    @AccessibilityFocusState private var cameraFocused: Bool
    @State private var typed = ""
    @FocusState private var typing: Bool
    @ObservedObject private var appLang = AppLangObserver.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch controller.phase {
            case .choosing: choices
            case .asking: asking
            case .aiming, .capturing: aiming
            case .taken: taken
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            controller.setVoice(voiceIdentifier)
            #if DEBUG
            if let word = AimFake.word {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { controller.submit(word) }
            }
            #endif
        }
        .onDisappear { controller.shutdown() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.resume() } else { controller.pause() }
        }
    }

    // MARK: Choices

    private var choices: some View {
        VStack(spacing: 18) {
            topBar(title: L("Help Me Aim"), back: {
                controller.shutdown()
                onBack()
            }, backLabel: L("Back to home"))
            Text(L("What do you want a picture of?"))
                .font(.title2.weight(.semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            AimBigButton(emoji: "🙂", title: L("Face"), color: .pink,
                         hint: L("Finds faces and talks you into the shot, then takes the picture")) {
                controller.chooseFace()
            }
            AimBigButton(emoji: "🖼️", title: L("Picture or Page"), color: .blue,
                         hint: L("Finds a page, a sign or a picture on the wall and gets all of it in the shot")) {
                controller.choosePage()
            }
            AimBigButton(emoji: "🔎", title: L("Something Else"), color: .orange,
                         hint: L("Say what you're looking for, like keys or a cup")) {
                controller.chooseSomethingElse()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: Asking

    private var asking: some View {
        VStack(spacing: 18) {
            topBar(title: L("Something Else"), back: { controller.backToChoices() }, backLabel: L("Back to choices"))
            Text(L("What are you looking for?"))
                .font(.title2.weight(.semibold))
                .foregroundColor(.white)
                .accessibilityAddTraits(.isHeader)
            AimListenButton(listener: controller.listener) { controller.listen() }
            if !controller.recentTargets.isEmpty {
                recentTargetButtons
            }
            if !controller.statusText.isEmpty, controller.statusText != L("What are you looking for?") {
                Text(controller.statusText)
                    .font(.headline)
                    .foregroundColor(.yellow)
                    .multilineTextAlignment(.center)
                    .accessibilityHidden(true)
            }
            HStack {
                TextField(L("Or type it"), text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($typing)
                    .onChange(of: typing) { _, now in if now { controller.typingStarted() } }
                    .onSubmit { controller.submit(typed) }
                    .accessibilityLabel(L("Or type what you're looking for"))
                Button(L("Find")) { controller.submit(typed) }
                    .buttonStyle(.borderedProminent)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    /// Things found before, one tap to look again (Kareen, 2026-09-25).
    private var recentTargetButtons: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(controller.recentTargets, id: \.self) { word in
                    Button {
                        controller.typingStarted()
                        controller.submit(word)
                    } label: {
                        Text(AimRecentTargets.title(word))
                            .font(.title3.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                            .overlay(Capsule().stroke(Color.white.opacity(0.7), lineWidth: 1.5))
                    }
                    .accessibilityLabel(L("Look for %@", word))
                }
            }
            Button(L("Clear list")) { controller.clearRecentTargets() }
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .accessibilityLabel(L("Clear recent items"))
        }
    }

    // MARK: Aiming

    private var aiming: some View {
        ZStack {
            AimCameraPreview(controller: controller)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    AimDevLog.note("[tap] double")
                    controller.shootNow()
                }
                .accessibilityElement()
                .accessibilityLabel(L("Camera, looking for %@", controller.subject?.lineName ?? L("your subject")))
                .accessibilityHint(L("Double tap to take the picture now"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { controller.shootNow() }
                .accessibilityFocused($cameraFocused)

            VStack {
                HStack(spacing: 12) {
                    smallButton(L("Back"), system: "chevron.left", label: L("Back to choices")) {
                        controller.backToChoices()
                    }
                    Spacer()
                    if controller.subject == .face {
                        smallButton(nil, system: "arrow.triangle.2.circlepath.camera",
                                    label: controller.cameraPosition == .back ? L("Switch to front camera") : L("Switch to back camera")) {
                            controller.toggleCamera()
                        }
                    }
                    if controller.cameraPosition == .back {
                        smallButton(nil, system: controller.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                                    label: controller.torchOn ? L("Flashlight, on") : L("Flashlight, off")) {
                            controller.toggleTorch()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
                if let word = controller.countdownWord {
                    Text(word)
                        .font(.system(size: 120, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(radius: 8)
                        .accessibilityHidden(true)
                }
                Spacer()
                // Visible for sighted helpers; VoiceOver hears the spoken line
                // instead, so this is hidden to avoid saying it twice.
                VStack(spacing: 6) {
                    if controller.loadingModel {
                        ProgressView().tint(.white)
                    }
                    Text(controller.statusText)
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    Text(L("Double tap anywhere to take it now"))
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.55))
                .cornerRadius(14)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .accessibilityHidden(true)
            }
        }
        .accessibilityAction(.magicTap) {
            AimDevLog.note("[tap] magic")
            controller.shootNow()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { cameraFocused = true }
        }
    }

    // MARK: Taken

    private var taken: some View {
        // Scrolls: a long description was cut to "..." on a phone screen
        // with the photo above it (Matt, 2026-11-03).
        ScrollView {
        VStack(spacing: 18) {
            topBar(title: L("Picture taken"), back: { controller.backToChoices() }, backLabel: L("Back to choices"))
            if let photo = controller.lastPhoto {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(12)
                    .frame(maxHeight: 360)
                    .accessibilityLabel(L("The picture you just took"))
            }
            Text(controller.statusText)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            AimBigButton(emoji: "📸", title: L("Take Another"), color: .green,
                         hint: L("Aim at %@ again", controller.subject?.lineName ?? L("the same thing"))) {
                controller.takeAnother()
            }
            AimBigButton(emoji: "↩️", title: L("Back"), color: .gray, hint: L("Back to the three choices")) {
                controller.backToChoices()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        }
    }

    // MARK: Pieces

    private func topBar(title: String, back: @escaping () -> Void, backLabel: String) -> some View {
        HStack {
            smallButton(L("Back"), system: "chevron.left", label: backLabel, action: back)
            Spacer()
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Color.clear.frame(width: 80, height: 1)
        }
        .padding(.top, 8)
    }

    private func smallButton(_ text: String?, system: String, label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: system)
                if let text { Text(text) }
            }
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.white)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .overlay(Capsule().stroke(Color.white.opacity(0.7), lineWidth: 1.5))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}

struct AimBigButton: View {
    let emoji: String
    let title: String
    let color: Color
    let hint: String
    /// VoiceOver label when it should say more than the visible title.
    var label: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(emoji).font(.system(size: 34))
                // Spanish runs longer ("Escuchando… toca para detener"): wraps, centered.
                OutlinedText(text: title, fontSize: 24)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(LinearGradient(colors: [Color.white.opacity(0.23), color.opacity(0.55)],
                                             startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.8), lineWidth: 4)
                    RoundedRectangle(cornerRadius: 22).stroke(color, lineWidth: 2)
                }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? title)
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
    }
}

private struct AimListenButton: View {
    @ObservedObject var listener: AimWordListener
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            AimBigButton(emoji: listener.isRunning ? "👂" : "🎙️",
                         title: listener.isRunning ? L("Listening… tap to stop") : AimPhrases.speakTitle,
                         color: listener.isRunning ? .red : .purple,
                         hint: listener.isRunning ? L("Stops listening now") : AimPhrases.speakHint,
                         label: listener.isRunning ? L("Listening… tap to stop") : AimPhrases.speakLabel,
                         action: action)
            if !listener.transcript.isEmpty {
                // Shown for sighted helpers; the spoken reply covers VoiceOver.
                Text(L("Heard: %@", listener.transcript))
                    .foregroundColor(.white)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: Burst processing

/// Runs off the main thread: finds the subject in every burst frame, keeps
/// the ONE best-framed, sharpest frame (Matt's rule: one photo per burst, the
/// rest are dropped here and never written anywhere), and crops it.
enum AimShotProcessor {
    /// The single photo kept from a burst.
    struct Kept {
        /// What goes to Photos: the winner (cropped or not) with its pixels
        /// turned upright, so no viewer can show it sideways.
        var photo: Data
        /// The winner as shot (sensor-landscape pixels plus an EXIF turn).
        var original: Data
        var cropped: Bool
        var info: ShotInfo
    }

    struct Result {
        var image: UIImage?
        var keep: Kept?
    }

    struct FrameInfo: Codable, Equatable {
        var index: Int
        var box: [CGFloat]?
        var sharpness: Double
        var score: Double?
    }

    /// Scores only; no pixels of the discarded frames.
    struct ShotInfo: Codable, Equatable {
        var subject: String
        var winner: Int
        var imageWidth: CGFloat
        var imageHeight: CGFloat
        var crop: [CGFloat]?
        /// Picture or Page squared up from these corners (x, y pairs,
        /// normalized) instead of cropped.
        var straightened: [CGFloat]? = nil
        var frames: [FrameInfo]
    }

    /// Long side of the copy the detector looks at.
    static let analysisSide: CGFloat = 1024

    static func process(_ frames: [Data],
                        snapshot: (kind: AimFrameAnalyzer.Kind, ids: Set<Int32>, finder: AimObjectFinder?)?,
                        framing: AimSteering.Framing, subjectName: String) -> Result {
        let scored: [AimBurst.Frame] = frames.map { data in
            autoreleasepool {
                guard let small = uprightImage(data, maxSide: analysisSide) else {
                    return AimBurst.Frame(box: nil, sharpness: 0)
                }
                if let snapshot {
                    return AimFrameAnalyzer.analyzeStill(
                        small, kind: snapshot.kind, finder: snapshot.finder, ids: snapshot.ids)
                }
                return AimBurst.Frame(box: nil, sharpness: FrameQualityGate.check(small, checkDocumentEdges: false).sharpness)
            }
        }
        return keepOne(frames, scored: scored, framing: framing, subjectName: subjectName)
    }

    /// Picks the winner and builds the one photo to keep. Separate from the
    /// detector so the one-photo rule is unit tested.
    static func keepOne(_ frames: [Data], scored: [AimBurst.Frame],
                        framing: AimSteering.Framing, subjectName: String) -> Result {
        guard frames.count == scored.count,
              let winner = AimBurst.pick(scored, framing: framing) else { return Result() }
        let original = frames[winner]
        let size = pixelSize(original)
        var crop: CGRect?
        var straightened: AimQuad?
        var photo = original
        var shown: UIImage?
        // Walkaround 2026-09-16: shots were read as sideways because the
        // pixels were landscape with only an EXIF turn. Bake the turn in.
        if let full = uprightImage(original, maxSide: max(size.width, size.height)) {
            var image = full
            let fullSize = CGSize(width: full.width, height: full.height)
            if framing == .page, let q = scored[winner].quad, AimStraighten.usable(q, imageSize: fullSize),
               let flat = squareUp(full, quad: q) {
                // Kareen, 2026-09-25: a picture shot at an angle is kept as
                // the picture itself, squared up.
                image = flat
                straightened = q
            } else if let box = scored[winner].box,
                      let rect = AimBurst.crop(box: box, imageSize: size, framing: framing),
                      let cut = full.cropping(to: rect) {
                image = cut
                crop = rect
            }
            if let jpeg = uprightJPEG(image, metadataFrom: original) {
                photo = jpeg
                shown = UIImage(cgImage: image)
            } else {
                crop = nil
                straightened = nil
            }
        }
        if shown == nil { shown = UIImage(data: original) }
        let info = ShotInfo(
            subject: subjectName, winner: winner, imageWidth: size.width, imageHeight: size.height,
            crop: crop.map { [$0.minX, $0.minY, $0.width, $0.height] },
            straightened: straightened.map { $0.corners.flatMap { [$0.x, $0.y] } },
            frames: scored.enumerated().map { i, f in
                FrameInfo(index: i, box: f.box.map { [$0.minX, $0.minY, $0.width, $0.height] },
                          sharpness: f.sharpness, score: AimBurst.score(f, framing: framing))
            })
        return Result(image: shown, keep: Kept(photo: photo, original: original,
                                               cropped: crop != nil || straightened != nil, info: info))
    }

    private static let squareUpContext = CIContext(options: [.useSoftwareRenderer: false])

    /// The page inside `quad` (normalized, top-left origin) flattened to a
    /// rectangle, at the size `AimStraighten.outputSize` gives.
    static func squareUp(_ image: CGImage, quad: AimQuad) -> CGImage? {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        // Core Image puts the origin at the bottom-left.
        func ci(_ p: CGPoint) -> CIVector { CIVector(x: p.x * W, y: (1 - p.y) * H) }
        guard let flat = CIFilter(name: "CIPerspectiveCorrection", parameters: [
            kCIInputImageKey: CIImage(cgImage: image),
            "inputTopLeft": ci(quad.topLeft), "inputTopRight": ci(quad.topRight),
            "inputBottomRight": ci(quad.bottomRight), "inputBottomLeft": ci(quad.bottomLeft),
        ])?.outputImage else { return nil }
        let want = AimStraighten.outputSize(quad, imageSize: CGSize(width: W, height: H))
        let e = flat.extent
        guard e.width > 0, e.height > 0 else { return nil }
        let scaled = flat.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: want.width / e.width, y: want.height / e.height))
        return squareUpContext.createCGImage(scaled, from: CGRect(origin: .zero, size: want))
    }

    /// The still, turned upright (EXIF applied), no bigger than `maxSide`.
    static func uprightImage(_ data: Data, maxSide: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxSide),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// JPEG of an already-upright image, keeping the shot's camera metadata
    /// but with the orientation reset to "up".
    static func uprightJPEG(_ image: CGImage, metadataFrom data: Data) -> Data? {
        var props: [CFString: Any] = [:]
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            props = p
        }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyColorModel, kCGImagePropertyProfileName] {
            props.removeValue(forKey: key)
        }
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            props[kCGImagePropertyExifDictionary] = exif
        }
        props[kCGImageDestinationLossyCompressionQuality] = 0.92
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Pixel size after the EXIF rotation.
    static func pixelSize(_ data: Data) -> CGSize {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { return .zero }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
}

#if HELP_ME_AIM_SHOT_LOG
// MARK: TEST-ONLY shot log

/// DEV-INSTALL AID ONLY. Compiled in only when HELP_ME_AIM_SHOT_LOG is passed
/// on the xcodebuild command line for Matt's dev install; it is never set in
/// the project file, so a TestFlight/App Store archive cannot contain it.
/// Writes the kept photo (and the uncropped winner when it was cropped) plus
/// the burst scores to Documents/HelpMeAimShots. Never the other frames.
enum TestShotLog {
    static func write(_ kept: AimShotProcessor.Kept) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("HelpMeAimShots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        try? kept.original.write(to: dir.appendingPathComponent("\(stamp)-winner.jpg"))
        let saved = kept.cropped ? "saved-cropped" : "saved"
        try? kept.photo.write(to: dir.appendingPathComponent("\(stamp)-\(saved).jpg"))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let json = try? enc.encode(kept.info) {
            try? json.write(to: dir.appendingPathComponent("\(stamp)-info.json"))
        }
    }
}
#endif


/// Help Me Aim in Your language: the thing to find is put into English before the
/// existing (English) word matching. Pure around `translate`, unit tested.
enum AimLanguage {
    static func wordForMatching(_ text: String, lang: String = YourLanguage.activeCode,
                                translate: AnswerLanguage.Translate = YourLanguage.translate) async -> String {
        let english = await AnswerLanguage.questionForModel(text, lang: lang, translate: translate)
        // Translators answer a bare noun with an article ("a cup", "the mug").
        return english.replacingOccurrences(of: #"^(?i)(a|an|the)\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
