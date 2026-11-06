// Live Cam: a conversation with the camera, all on the phone (ported 2026-11-04 from Moonstone's Live camera,
// LiveCallController.swift; every tuning note is Matt's and kept). It greets, then listens the whole time;
// ~1 s of quiet ends a question; the frame at the end of the question goes to the on-device vision model (the
// same level What's this? uses); the answer is spoken sentence by sentence as it is written, in Your language;
// talking over it stops it. While you're quiet it checks in now and then and, if Speak up is on, mentions a
// thing it has never named once it has double-checked it is really there. No network at all.
//
// Left out of the port on purpose: Moonstone's call recorder (mic audio + frames saved for every call) and its
// release-build session logs. RT Cam saves nothing; the timing log below is debug builds only.
import AVFoundation
import Combine
import SwiftUI
import UIKit

/// The streamed answer, shared by the model's thread (writes) and the main thread (speaks).
/// The repeat guard for one answer: its first sentence is checked against the last answer before anything is spoken.
final class LiveRepeatGuard: @unchecked Sendable {
    var checked = false
    var repeated = false
}

/// The parts of opening Live Cam that wait on the system (permission prompts, the model load).
struct LiveStartSteps {
    var releaseOther: @MainActor () async -> Void = { await OnDeviceVisionNarrator.shared.releaseEngine() }
    var loadEngine: @Sendable (ModelLevel) -> LiveVisionEngine? = { try? LiveVisionEngine(level: $0) }
    var requestCamera: @MainActor () async -> Bool = { await LiveCamera.requestAccess() }
    var willAskPermission: @MainActor () -> Bool = { LiveListener.willAskPermission }
    var startListener: @MainActor (LiveListener) async -> LiveListener.Failure? = { await $0.start() }
}

final class LiveStreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stream = LiveSentenceStream()
    private var alive = true
    private(set) var lastText = ""
    private(set) var sentences: [String] = []
    var isAlive: Bool { lock.lock(); defer { lock.unlock() }; return alive }
    func cancel() { lock.lock(); alive = false; lock.unlock() }
    func feed(_ text: String, final: Bool = false) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard alive else { return [] }
        if !final { lastText = text }
        let out = stream.feed(text, final: final)
        sentences += out
        return out
    }
}

@MainActor
final class LiveCallController: ObservableObject {
    enum Phase: Equatable { case starting, downloading, loading, listening, thinking, speaking, ended, failed }

    /// The talking style (normal, funny, analyze, coach), switched by voice or the dropdown. Every Live camera opens in
    /// Normal (Matt 11/2: it reopened in Coach and confused him); the camera side is still remembered.
    @Published var mode: LiveMode = .normal {
        didSet { prefilled = nil }
    }
    /// Coach's topic ("your jump shot", "changing a tire"), asked for when Coach turns on (11/3 Matt).
    private var coachGoal: String?
    private var awaitingCoachGoal = false

    @Published private(set) var phase: Phase = .starting { didSet { if phase != oldValue { log(["event": "phase", "phase": "\(phase)"]) } } }
    /// One or two lines over the camera: what it is saying now, or what it last saw.
    @Published private(set) var caption = ""
    /// The language the caption is in (VoiceOver reads it with a voice for it).
    @Published private(set) var captionLang = AppLang.code
    /// The welcome is heard, never shown (Matt 11/6: "it does not need one on screen").
    @Published private(set) var captionIsIntro = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var micLevel: Float = -60
    /// The model is reading a photo or writing: the orb holds still so the GPU is all the model's.
    @Published private(set) var modelBusy = false
    @Published var micMuted = false { didSet { micMutedChanged() } }
    /// 11/2 Matt: a sign on screen when it's out of its league (guessing, lost the thread, or past what it can do).
    @Published private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?
    func showNotice(_ text: String) {
        notice = text; log(["event": "notice", "text": text])
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in try? await Task.sleep(nanoseconds: 9_000_000_000); if !Task.isCancelled { self?.notice = nil } }
    }

    /// Words on screen. RT Cam shows them by default (low vision reads them big); VoiceOver reads them either way.
    @Published var showCaption = UserDefaults.standard.object(forKey: "liveCamShowCaption") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showCaption, forKey: "liveCamShowCaption") }
    }
    /// Speak up: check-ins after a long quiet and a line about a thing it has never named.
    @Published var proactiveOn = UserDefaults.standard.object(forKey: "liveCamProactive") as? Bool ?? true {
        didSet { UserDefaults.standard.set(proactiveOn, forKey: "liveCamProactive"); watch.enabled = proactiveOn }
    }
    /// The flashlight (Matt 11/6), back camera only: one tap on, one tap off.
    @Published private(set) var torchOn = false
    var torchAvailable: Bool {
        #if DEBUG
        if LiveCamTest.active { return true }   // the harness has no camera: the button and its state still work
        #endif
        return LiveCamera.torchAvailable
    }
    /// Turning it on from the selfie camera flips to the back camera first (the selfie side has no light).
    func setFlashlight(_ on: Bool, spoken: Bool = false) {
        guard running, torchAvailable else { return }
        if on, camera.isFront { flip() }
        camera.setTorch(on)
        torchOn = on
        log(["event": "flashlight", "on": on, "spoken": spoken])
        if spoken {
            // Never the same words twice in a row (the repeat guard), but always said: the light changed.
            let lines = on ? ["Flashlight, on", "Light's on."] : ["Flashlight, off", "Light's off."]
            speakAll(own: lines.first { sayGuard.vet($0) != nil && LiveSayGuard.opening($0) != sayGuard.lastOpening } ?? lines[0])
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
    /// Flip camera: the light goes off when it flips to the selfie side.
    func flip() {
        if !camera.isFront { torchOn = false }
        camera.flip()
    }
    private var backgroundWatch: NSObjectProtocol?

    /// The last question heard (in the person's words), shown above the answer.
    @Published private(set) var heardText = ""
    /// Speech recognition kept failing the moment it started: the mic is off for this visit and a typing box shows.
    @Published private(set) var hearingStopped = false

    let camera = LiveCamera()
    let listener = LiveListener()
    /// A var only so tests can hand in a silent voice before start().
    var voice: LiveVoiceOutput = LiveAppleVoice()
    private var engine: LiveVisionEngine?
    private var preload: Task<LiveVisionEngine?, Never>?
    private var startTask: Task<Void, Never>?
    /// The steps of opening that wait on the system; tests swap them to close Live Cam in the middle of one.
    var steps = LiveStartSteps()
    /// Test builds: a typed question instead of the mic (LiveCamTest).
    var typedOnly = false
    /// A no-photo turn still runs through look(); this stands in for the frame and is never sent.
    nonisolated static let noFrame: CGImage? = {
        let c = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        return c?.makeImage()
    }()

    private var memory = LiveMemory()
    /// Matt 11/6: never the same sentence twice, one help offer per visit, no two lines opening the same way.
    private var sayGuard = LiveSayGuard()
    private var checkInTurns = LiveRotation()
    /// This turn's model sentences: how many were said and how many were dropped as repeats.
    private var tally = (turn: -1, said: 0, dropped: 0)
    private var watch = LiveProactive()
    private var current: LiveStreamBox?
    private var turn = 0
    private var answerDone = true
    private var lastAck: String?
    /// Seconds from a question to its first sentence on this phone, from the last answer.
    private var recentFirstSentence: Double?
    private var questionEndedAt: Date?
    /// How long the last photo took to read on this phone; a slow phone gets a smaller photo.
    private var recentEncodeMs: Double = 0
    private var watchTask: Task<Void, Never>?
    private(set) var running = false
    private var openedAt: Date?
    var onEnd: (() -> Void)?

    func log(_ o: [String: Any]) { LiveCamTest.log(o) }

    // MARK: Start / end

    func start() {
        guard !running else { return }
        running = true
        moneyMemory.forget()   // a new call never answers from an old count
        Task.detached(priority: .utility) { MoneyDetector.warmUp() }   // both money models loaded off the main thread
        UIApplication.shared.isIdleTimerDisabled = true
        // The app goes to the background: the light goes off (iOS stops the camera there anyway).
        backgroundWatch = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.torchOn == true { self?.camera.setTorch(false); self?.torchOn = false } }
        }
        watch.enabled = proactiveOn
        LiveCamTest.beginSession()
        openedAt = Date()
        // Nothing else in the app talks while Live Cam is open.
        SpeechManager.shared.resetSpeechState()
        let level = LiveCamModel.level
        log(["event": "open", "test": LiveCamTest.active, "level": level.rawValue,
             "thermal": ProcessInfo.processInfo.thermalState.rawValue])
        configureTest()
        voice.onStart = { [weak self] shown, english, lang in
            guard let self else { return }
            self.caption = shown
            self.captionLang = lang
            self.captionIsIntro = english == LiveWords.firstGreeting
            self.lastSaid = english
            self.log(["event": "say", "text": shown])
            if let o = self.openedAt { self.openedAt = nil; self.log(["event": "first_spoken_after_open", "seconds": Date().timeIntervalSince(o)]) }
            if english == self.lastAck, self.questionEndedAt != nil {
                self.log(["event": "ack_spoken", "after_end_of_speech": Date().timeIntervalSince(self.questionEndedAt!)])
            } else if let ended = self.questionEndedAt {
                self.questionEndedAt = nil
                self.log(["event": "first_words", "after_end_of_speech": Date().timeIntervalSince(ended)])
            }
        }
        voice.onQuiet = { [weak self] in self?.wentQuiet() }
        listener.onQuestion = { [weak self] q, at, conf, fin in self?.heardInTheirLanguage(q, endedAt: at, confidence: conf, isFinal: fin) }
        listener.onBargeHeard = { [weak self] t, c in self?.heardWhileTalking(t, confidence: c) }
        listener.onGaveUp = { [weak self] in self?.hearingGaveUp() }
        listener.onRetry = { [weak self] in
            guard let self, self.running, self.phase == .listening, !self.micMuted, !self.hearingStopped else { return }
            self.listener.listen()
        }
        listener.onLevel = { [weak self] l in self?.micLevel = l }
        listener.onPartial = { [weak self] t in self?.log(["event": "partial", "text": t]); self?.startPrefill() }
        startTask = Task { await runStart(level) }
    }

    /// Each step of opening Live Cam can await (a permission prompt, the "why" line, the model). Back can be tapped
    /// during any of them: after every await this checks that the visit is still open, and whatever a step turned on
    /// after Back was tapped is turned off again, so a closed Live Cam never leaves the camera or mic on.
    private func runStart(_ level: ModelLevel) async {
        await steps.releaseOther()
        guard stillOpen("released") else { return }
        // Load the model while the camera, mic and voice start.
        let load = steps.loadEngine
        preload = Task.detached(priority: .userInitiated) { load(level) }
        if !typedOnly {
            let allowed = await steps.requestCamera()
            guard stillOpen("camera_permission") else { return }
            guard allowed else {
                fail(LiveCamWords.needsCamera); return
            }
        }
        camera.onEvent = { [weak self] o in DispatchQueue.main.async { MainActor.assumeIsolated { self?.log(o) } } }
        camera.start()
        if !typedOnly {
            if steps.willAskPermission() {
                // The first time: say why before iOS asks (blind users hear the reason, then the two prompts).
                phase = .speaking
                caption = L(LiveCamWords.permissionLine)
                captionIsIntro = false
                captionLang = AppLang.code
                voice.sayOwn(LiveCamWords.permissionLine)
                while running, voice.isBusy { try? await Task.sleep(nanoseconds: 150_000_000) }
                guard stillOpen("permission_line") else { return }
            }
            let failure = await steps.startListener(listener)
            guard stillOpen("listener") else { return }
            if let f = failure {
                fail(f == .notAllowed ? LiveCamWords.notAllowed : LiveCamWords.noOfflineSpeech)
                return
            }
        }
        await prepareModel(level)
    }

    /// False once Back was tapped while opening; then everything a step may have turned on since is turned off again.
    private func stillOpen(_ step: String) -> Bool {
        if running, !Task.isCancelled { return true }
        log(["event": "closed_while_opening", "step": step])
        tearDown()
        return false
    }

    /// Camera, mic, recognizer, voice and model off. Safe to call more than once.
    private func tearDown() {
        watchTask?.cancel()
        current?.cancel(); current = nil
        voice.onQuiet = nil
        voice.stop()
        listener.shutdown()
        camera.stop()   // the light goes off with it
        torchOn = false
        if let b = backgroundWatch { NotificationCenter.default.removeObserver(b); backgroundWatch = nil }
        // The model is let go (What's this? loads its own copy when it is next used).
        preload?.cancel(); preload = nil
        engine = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// What's running right now (tests: nothing may be left on after Back).
    var anythingRunning: Bool { listener.isRunning || listener.isListening || camera.isWanted || engine != nil || preload != nil }

    func end() {
        guard running else { return }
        running = false
        startTask?.cancel(); startTask = nil
        tearDown()
        phase = .ended
        log(["event": "ended"])
        onEnd?()
    }

    /// `why`: the English key of the app's own line, said and shown in the app language.
    private func fail(_ why: String) {
        guard running else { return }
        phase = .failed
        caption = L(why)
        captionIsIntro = false
        captionLang = AppLang.code
        log(["event": "failed", "why": why])
        voice.sayOwn(why)
    }

    private func prepareModel(_ level: ModelLevel) async {
        log(["event": "level", "level": level.rawValue])
        phase = .loading
        let t0 = Date()
        if let p = preload { engine = await p.value }
        preload = nil
        guard stillOpen("model") else { return }
        if engine == nil, level != .balanced {
            // The picked level wouldn't load: the bundled Balanced, always on the phone.
            log(["event": "level_fallback", "from": level.rawValue])
            let load = steps.loadEngine
            engine = await Task.detached(priority: .userInitiated) { load(.balanced) }.value
            guard stillOpen("model_fallback") else { return }
        }
        guard engine != nil else {
            fail(LiveCamWords.modelFailed)
            log(["event": "load failed"])
            return
        }
        log(["event": "loaded", "seconds": Date().timeIntervalSince(t0)])
        guard stillOpen("loaded") else { return }
        // Greet like a friend, then wait for cues (11/2 Matt): it only looks when asked.
        phase = .speaking
        listener.watchForBargeIn(true)
        describedOnce = true
        memory = LiveMemory()
        sayGuard = LiveSayGuard()
        checkInTurns = LiveRotation()
        say(.own(LiveWords.firstGreeting))
        if !typedOnly { look(prompt: LiveWords.openingLook, unprompted: false, first: true) }   // what's around, once (11/2 Matt)
        else { answerDone = true }
        if LiveCamTest.forceCantHear { hearingGaveUp() }
    }

    // MARK: Turn taking

    private func wentQuiet() {
        guard running, answerDone, phase == .speaking || phase == .thinking else { return }
        let my = turn
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(LiveTiming.afterSpeaking * 1e9))
            guard self.running, self.turn == my, !self.voice.isBusy, self.answerDone else { return }
            self.lastSpokeEnd = Date()
            self.listen()
        }
    }

    private func listen() {
        guard running else { return }
        prefillArmed = true
        listener.watchForBargeIn(false)
        phase = .listening
        if !micMuted, !typedOnly, !hearingStopped { listener.listen() }
        if !typedOnly { startWatch() }
    }

    private func micMutedChanged() {
        log(["event": "mic", "muted": micMuted])
        listener.muted = micMuted
        if micMuted { listener.stopListening() }
        else if phase == .listening, !hearingStopped { listener.listen() }
        else if phase == .speaking || phase == .thinking, !hearingStopped { listener.watchForBargeIn(true) }
    }

    /// The recognizer gave up (see LiveListener.recognizerFailed): say so in words, show it, offer typing.
    func hearingGaveUp() {
        guard running, !hearingStopped else { return }
        hearingStopped = true
        log(["event": "hearing_gave_up", "quick_failures": listener.quickFailures])
        // The mic itself goes off (no indicator, no battery), the voice keeps working.
        listener.stopMic()
        if phase == .listening || phase == .starting || phase == .loading {
            speakAll(own: LiveCamWords.cantHear)
        } else {
            voice.sayOwn(LiveCamWords.cantHear)   // after the answer it is giving, never instead of it
        }
    }

    /// Talked over: stop now and take the new question (first words kept).
    /// The start of a sentence that was cut off at a pause: the rest gets joined on (11/1 phone test: "Tell me everything
    /// you see… in this room" ended at the pause, the rest counted as an interruption and the leftover was dropped).
    private var cutOff: (text: String, at: Date)?
    private var lastQuestion = ""

    /// Words heard while it talks or thinks (Matt 11/6): a cough, a murmur, side talk or its own voice never stop it;
    /// only a real question or a stop word for it does (LiveBargeIn.shouldInterrupt).
    private func heardWhileTalking(_ heard: String, confidence: Double?) {
        guard running, !micMuted, !hearingStopped, phase == .speaking || phase == .thinking else { return }
        let continuing = phase == .thinking && questionEndedAt.map { Date().timeIntervalSince($0) < 2.5 } == true
        let saying = [caption, lastSaid ?? ""] + memory.said.suffix(2)
        let lang = listener.heardLang
        let stop = LiveBargeIn.shouldInterrupt(heard, confidence: confidence, saying: saying, continuing: continuing, lang: lang)
        log(["event": "heard_while_talking", "text": heard, "interrupt": stop])
        if stop { bargeIn(heard: heard, dropWords: LiveBargeIn.afterEcho(heard, saying: saying, lang: lang)) }
    }

    /// Talked over with a real question: stop now and take it, the words heard so far kept.
    func bargeIn(heard: String = "", dropWords: Int = 0) {
        guard running, !micMuted, !hearingStopped, phase == .speaking || phase == .thinking else { return }
        // Still thinking and they kept talking right after: they weren't done, so keep what they said so far.
        if phase == .thinking, let e = questionEndedAt, Date().timeIntervalSince(e) < 2.5, !lastQuestion.isEmpty {
            cutOff = (lastQuestion, Date())
        }
        log(["event": "barge_in", "phase": "\(phase)", "heard": heard, "kept_start": cutOff?.text ?? ""])
        turn += 1
        current?.cancel(); current = nil
        answerDone = true
        voice.stop()
        phase = .listening
        prefillArmed = false
        listener.takeBargeAsQuestion(dropWords: dropWords)   // the same recognition carries on, its own echo left out
        if !typedOnly { startWatch() }
    }

    /// The orb tapped: stop talking and listen.
    func interrupt() {
        guard running, phase == .speaking || phase == .thinking else { return }
        stopTalking()
        listen()
    }

    private func stopTalking() {
        turn += 1
        current?.cancel(); current = nil
        answerDone = true
        voice.stop()
        listener.watchForBargeIn(false)
    }

    // MARK: Getting ready while they talk

    /// System + photo already in the model's context (Fable 10/31: ~300 ms of the ~430 ms photo read moves
    /// into the time they are still talking; the answer only reads the question's tokens).
    private struct Prefilled { let system: String; let thumb: [UInt8]; let at: Date }
    private var prefilled: Prefilled?
    private var prefillTask: Task<Void, Never>?
    private var prefillArmed = false

    /// First words of a question heard: read the current frame into the model now (512 px, the usual size).
    private func startPrefill(always: Bool = false) {
        guard running, always || prefillArmed, phase == .listening, current == nil, prefillTask == nil, let engine else { return }
        prefillArmed = false
        prefilled = nil
        let system = LiveWords.system   // the stylist only for an explicit "how do I look" (never pre-read)
        let camera = camera
        prefillTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let frame = camera.current() else { await MainActor.run { self?.prefillTask = nil }; return }
            let thumb = LiveCamera.thumb(frame)
            let r = engine.prefill(system: system, image: frame, longSide: 512)
            await MainActor.run {
                guard let self else { return }
                self.prefillTask = nil
                if r.ok { self.prefilled = Prefilled(system: system, thumb: thumb, at: Date()) }
                self.log(["event": "prefill", "ok": r.ok, "ms": r.ms.rounded()])
            }
        }
    }

    private var lastSaid: String?
    /// When it last finished talking: right after that, whatever is said is a reply to it (11/2 room-chatter balance).
    private var lastSpokeEnd = Date()
    /// When it last heard anyone (the listener's own clock restarts every 45 s, so it can't time a long quiet).
    private var lastHeardAt = Date()
    /// The running look is the quiet inventory (a list to compare, never spoken as is).
    private var inventoryLook = false
    private var lastNovelty = Date.distantPast
    /// The last question was about what's in view (a short "and that one?" follows it onto the camera).
    private var lastUsedPhoto = true
    /// It has told the person what it sees at least once this call (11/1: a noise cut the opening look off and it never
    /// described anything until asked).
    private var describedOnce = false
    private var lastSayAgain = Date.distantPast

    /// Your language: the question is put into English for the model and the English logic (stop, repeat,
    /// modes), the same as a What's this? follow-up. English: no change.
    private func heardInTheirLanguage(_ q: String, endedAt: Date, confidence: Double?, isFinal: Bool) {
        heardText = q
        guard YourLanguage.activeCode != YourLanguageRules.english else {
            heard(q, endedAt: endedAt, confidence: confidence, isFinal: isFinal); return
        }
        Task { @MainActor in
            let english = await YourLanguage.toEnglish(q)
            self.log(["event": "question_english", "text": english])
            self.heard(english, endedAt: endedAt, confidence: confidence, isFinal: isFinal)
        }
    }

    /// Test builds and the typed box: a question as if it had been heard (no mic).
    func ask(typed q: String) {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard running, !t.isEmpty else { return }
        stopTalking()
        listener.stopListening()
        heardInTheirLanguage(t, endedAt: Date(), confidence: nil, isFinal: true)
    }

    private func heard(_ q: String, endedAt: Date, confidence: Double?, isFinal: Bool) {
        guard running else { return }
        lastHeardAt = Date()
        var q = q
        if let c = cutOff {
            cutOff = nil
            if Date().timeIntervalSince(c.at) < 8 { q = c.text + " " + q; log(["event": "joined", "text": q]) }
        }
        let verdict = LiveWords.judge(q, confidence: confidence, isFinal: isFinal, lastSaid: lastSaid,
                                       sinceItSpoke: endedAt.timeIntervalSince(lastSpokeEnd))
        var entry: [String: Any] = ["event": "transcript", "text": q, "final": isFinal, "ended": endedAt.timeIntervalSince1970,
                                    "end_reason": listener.endReason]
        if let confidence { entry["confidence"] = (confidence * 100).rounded() / 100 }
        switch verdict {
        case let .ignore(why):
            entry["decision"] = "ignored: \(why)"; log(entry)
            listen(); return
        case .sayAgain:
            guard Date().timeIntervalSince(lastSayAgain) > 30 else {
                entry["decision"] = "ignored: unsure, already asked to repeat"; log(entry); listen(); return
            }
            lastSayAgain = Date()
            entry["decision"] = "asked to say it again"; log(entry)
            speakAll(own: LiveCamWords.sayAgain); return
        case .answer:
            entry["decision"] = "answered"; log(entry)
        }
        watch.personSpoke()
        lastQuestion = q
        notice = nil
        // It only keeps the last couple of exchanges (90 s): "what did I ask first" is past its memory, say so.
        if LiveWords.reachesBack(q) {   // it keeps only the last two exchanges, so reaching back is past it (run 2)
            showNotice("Lost track — ask the whole question again")
            speakAll(own: LiveCamWords.lostTrack)
            return
        }
        if LiveWords.pastItsLeague(q) { showNotice("Past what I can do offline — double-check this one") }
        askedAboutMe = LiveWords.isAboutLiveCam(q)
        log(["event": "question", "text": q, "ended": endedAt.timeIntervalSince1970])
        switch LiveWords.turn(q) {
        case .end:
            voice.sayOwn(LiveCamWords.bye)
            Task { @MainActor in try? await Task.sleep(nanoseconds: 1_500_000_000); self.end() }
        case .stopSaying:
            questionEndedAt = endedAt
            speakAll(own: LiveCamWords.gotIt)
        case .hush:
            stopTalking()
            listen()
        case let .light(on):
            questionEndedAt = endedAt
            setFlashlight(on ?? !torchOn, spoken: true)
        case let .mode(m):
            questionEndedAt = endedAt
            let rest = LiveWords.modeRest(q)
            if m == .coach, let goal = rest.flatMap(LiveWords.coachGoal) {
                // "Coach me on my jump shot": the goal is set, no need to ask for it.
                setMode(m, say: .withContent(LiveCamWords.coachGoalSet, goal), goal: goal)
            } else if m == .analyze, rest != nil {
                // "Analyze the forces on this shelf": switch AND answer it.
                setMode(m, quiet: true)
                ask(q, endedAt: endedAt)
            } else {
                setMode(m)
            }
        case .repeatLast:
            questionEndedAt = endedAt
            if let last = memory.lastAnswer { speakAll(content: last) } else { speakAll(own: LiveCamWords.nothingSaidYet) }
        case .ask:
            ask(q, endedAt: endedAt)
        }
    }

    private func ask(_ q: String, endedAt: Date) {
        questionEndedAt = endedAt
        // Coach asked "what do you want coaching on?": this reply is the goal (11/3 Matt: basketball, a task, anything).
        if mode == .coach, awaitingCoachGoal {
            awaitingCoachGoal = false
            coachGoal = LiveWords.coachGoal(q)
            log(["event": "coach_goal", "goal": coachGoal ?? ""])
            if let goal = coachGoal, !LiveWords.isQuestionOrAsk(" " + LiveWords.normalize(q) + " ") {
                speakAll(.withContent(LiveCamWords.coachGoalHeard, goal))
                return
            }
        }
        // 11/4 Matt's money videos: "$600", "$7 total", "$36" for $129. Money is counted in code (LiveMoney), never
        // guessed by the model. Only "how many twenties" after a SURE count is answered from that count; a total,
        // "how much is that" or "are you sure" always looks again (the pile may have changed), and any other
        // question forgets the count (11/6 review).
        switch LiveMoney.route(q, last: moneyMemory.recent()) {
        case .fromLastCount:
            guard let last = moneyMemory.recent() else { break }
            let english = LiveMoney.followUp(q, last: last)
            let line = moneyLang == .en ? english : LiveMoney.followUp(q, last: last, lang: moneyLang)
            log(["event": "money_follow_up", "question": q, "answer": english])
            memory.note(question: q, answer: english)
            current?.cancel(); current = nil   // a count still running is not said over this answer (11/6 review)
            turn += 1
            answerDone = true
            phase = .speaking
            listener.watchForBargeIn(true)
            sayMoney(line, english: english)
            lastUsedPhoto = true
            return
        case .countAgain:
            lastUsedPhoto = true
            countMoney(q)
            return
        case .notMoney:
            moneyMemory.forget()
        }
        // 11/1 Matt: "it should always be taking in the photo". Every question goes with the live frame; a
        // general one keeps the chat voice and only uses the photo if it helps.
        if !LiveWords.needsPhoto(q, lastUsedPhoto: lastUsedPhoto) {
            lastUsedPhoto = false
            look(prompt: LiveWords.chatQuestion(q, history: []) + " " + LiveWords.photoIfHelps,
                 unprompted: false, question: q, general: true)
            return
        }
        lastUsedPhoto = true
        // "How do I look" with the back camera: it can't see them, so say so instead of describing the room.
        if !camera.isFront, LiveWords.isLooksQuestion(q) {
            speakAll(own: LiveCamWords.flipToSeeYou)
            return
        }
        // 11/1 phone test: with earlier questions in the prompt the 2B model answered the PREVIOUS one ("how far is the
        // moon" got the desk). Only a short pointing follow-up ("what about that one") carries the one before it.
        var prompt = LiveWords.question(q, history: LiveWords.isShortFollowUp(q) ? Array(memory.recent().suffix(1)) : [],
                                        selfieCritique: camera.isFront && LiveWords.isLooksQuestion(q))
        // Front camera: the person in view is the one talking ("a bald man with glasses" was Matt, 11/1).
        if camera.isFront { prompt += " The person in front of the camera is the one talking to you: call them \"you\"." }
        else if LiveWords.isAboutThem(q) { prompt += LiveWords.backCameraSelf }
        look(prompt: prompt, unprompted: false, question: q)
    }

    // MARK: Money

    private var moneyMemory = MoneyMemory()

    /// Money answers are the app's own words (LiveLine.own): said in the app language. Their numbers and plurals
    /// are built in code, so the Spanish comes from MoneyWordsES rather than the string catalog.
    private var moneyLang: MoneyLang { MoneyLang.from(AppLang.code) }
    private func sayMoney(_ line: String, english: String) {
        if moneyLang == .en { voice.sayOwn(english) } else { voice.sayLine(line, lang: AppLang.code, english: english) }
    }

    /// Counts the bills in view: the full camera frame (1280 x 720, not the 512 px look), each bill found and read
    /// on its own, the total added in code. One frame, a second only if a bill couldn't be read.
    private func countMoney(_ q: String) {
        moneyMemory.countStarted()   // no follow-up is answered from the old count while this one runs
        guard let engine else { speakAll(own: LiveCamWords.stillGettingReady); return }
        if UIApplication.shared.applicationState != .active {
            speakAll(own: LiveCamWords.cantSeeInBackground)
            return
        }
        current?.cancel()
        // Tracked like any answer, so "stop", the orb or a new question cancels it (11/6 review).
        let box = LiveStreamBox()
        current = box
        turn += 1
        let my = turn
        answerDone = false
        prefilled = nil   // the model's context is about to be used for the bills
        phase = .thinking
        listener.stopListening()
        listener.watchForBargeIn(true)
        voice.sayOwn("Let me count.")
        phase = .speaking
        modelBusy = true
        let camera = camera
        let asked = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            _ = MoneyDetector.models   // the models load here, off the main thread
            var first = true
            let count = LiveMoney.countBurst(maxFrames: 2, frame: { () -> CGImage? in
                guard box.isAlive else { return nil }   // cancelled: no more looks
                if !first { Thread.sleep(forTimeInterval: 0.3) }   // a moment apart, so the next frame isn't the same one
                first = false
                return camera.current()
            }, ask: { img, question in
                guard box.isAlive else { return nil }
                return engine.respond(system: LiveMoney.modelSystem, question: question, image: img,
                               longSide: LiveMoney.modelLongSide, maxTokens: 4)?.text
            }, onLook: { c, log in
                let doubts = c.doubts.map(\.rawValue)
                Task { @MainActor in
                    self?.log(["event": "money_look", "bills": c.bills.count, "values": c.values, "pile": c.pileValues,
                               "doubts": doubts, "detail": log.map { $0.mapValues { "\($0)" } }])
                }
            })
            await MainActor.run {
                guard let self else { return }
                // A newer answer owns modelBusy: only this run's own end (or nothing newer running) clears it.
                if self.current === box || self.current == nil { self.modelBusy = false }
                if self.current === box { self.current = nil }
                guard box.isAlive, self.running, self.turn == my else { return }
                let english = LiveMoney.sentence(count)
                let line = self.moneyLang == .en ? english : LiveMoney.sentence(count, lang: self.moneyLang)
                self.log(["event": "money_answer", "question": q, "answer": english, "sure": count.sure, "total": count.total,
                          "seconds": Date().timeIntervalSince(asked)])
                if !count.doubts.contains(.noCamera) { self.moneyMemory.note(count) }
                self.memory.note(question: q, answer: english)
                self.phase = .speaking
                self.listener.watchForBargeIn(true)
                self.sayMoney(line, english: english)
                self.answerDone = true
                if !self.voice.isBusy { self.wentQuiet() }
            }
        }
    }

    /// `say`: what to say instead of the usual confirm; `quiet`: say nothing (the answer follows). `goal`: Coach's topic.
    func setMode(_ m: LiveMode, tapped: Bool = false, say: LiveLine? = nil, quiet: Bool = false, goal: String? = nil) {
        mode = m
        coachGoal = m == .coach ? goal : nil
        awaitingCoachGoal = m == .coach && goal == nil
        log(["event": "mode", "mode": m.rawValue, "tapped": tapped, "goal": goal ?? ""])
        guard running else { return }
        current?.cancel(); current = nil
        listener.stopListening()
        if !quiet { speakAll(say ?? .own(m.confirm)) }
    }

    /// The mode button: Normal → Funny → Analyze → Coach → Normal.
    func nextMode() {
        let all = LiveMode.allCases
        setMode(all[(all.firstIndex(of: mode)! + 1) % all.count], tapped: true)
    }

    private func speakAll(_ line: LiveLine) {
        turn += 1
        answerDone = true
        phase = .speaking
        listener.watchForBargeIn(true)
        say(line)
    }
    private func speakAll(own english: String) { speakAll(.own(english)) }
    private func speakAll(content english: String) { speakAll(.content(english)) }

    /// Hands a line to the voice: the app's own words in the app language, content in Your language.
    private func say(_ line: LiveLine) {
        switch line {
        case let .own(english): sayGuard.note(english); voice.sayOwn(english)
        case let .content(english): sayGuard.note(english); voice.say(english)
        case let .withContent(format, piece):
            let english = String(format: format, piece)
            sayGuard.note(english)
            // Your language is the app language and its translator is ready (Spanish): the whole sentence is
            // translated, so the piece (the English goal or thing) never sits English inside a Spanish line.
            if LiveLine.translatesWhole(appCode: AppLang.code, yourCode: YourLanguage.activeCode) { voice.say(english) }
            else { voice.sayLine(L(format, piece), lang: AppLang.code, english: english) }
        }
    }

    // MARK: Looking

    /// Frame now + prompt → the model; sentences are spoken as they come. `unprompted` lines are
    /// only spoken if they say something new.
    private func look(prompt: String, unprompted: Bool, question: String? = nil, first: Bool = false, withPhoto: Bool = true,
                      general: Bool = false) {
        guard let engine else {
            if !unprompted { speakAll(own: LiveCamWords.stillGettingReady) }
            return
        }
        current?.cancel()
        turn += 1
        let my = turn
        answerDone = false
        let box = LiveStreamBox()
        current = box
        if !unprompted {
            phase = first ? .speaking : .thinking
            listener.stopListening()
            listener.watchForBargeIn(true)
            // A slow phone gets a tiny "let me look" first, never the same one twice in a row.
            // 11/2 speed pass: answers start in under a second, so "One moment" only delayed them. Only a slow answer
            // (the last one took over 1.6 s, or Analyze mode's bigger picture) gets the filler now.
            if !first, mode == .analyze || (recentFirstSentence ?? 0) > LiveTiming.ackAfter {
                let a = LiveWords.ack(after: lastAck)
                lastAck = a
                voice.sayOwn(a)
                phase = .speaking
            }
        }
        // 11/1: the voice keeps working with the phone locked or another app in front (background audio), but iOS
        // never lets the camera run there. Say so instead of answering about the last picture it had.
        if withPhoto, UIApplication.shared.applicationState != .active {
            log(["event": "camera_unavailable", "app_state": UIApplication.shared.applicationState.rawValue])
            answerDone = true
            if !unprompted { speakAll(own: LiveCamWords.cantSeeInBackground) }
            return
        }
        let asked = Date()
        let lastSeen = memory.lastSeen
        let lastAnswer = memory.lastAnswer
        let guardRepeat = LiveRepeatGuard()
        let lastView = watch.reference
        // 512 px unless the question needs detail: ~144 image tokens instead of ~336 (Fable 10/31, ~150 ms on the phone).
        let mode = self.mode
        // Zoomed in past 1.5x: the sharper photo, so small text it's pointed at can be read (11/2).
        let longSide = recentEncodeMs > 4000 || (mode != .analyze && camera.zoom < 1.5 && !LiveWords.needsDetail(question ?? "")) ? 512 : 768
        // 11/1 Matt: on the front camera it called his 7-year-old daughter's hair messy. The stylist critique is only
        // for someone who asks how THEY look; everything else, front camera or back, is the normal friendly voice.
        let stylist = camera.isFront && question != nil && LiveWords.isLooksQuestion(question ?? "")   // never just for Coach (11/3)
        let system = !withPhoto || general ? LiveWords.chatSystem : stylist ? LiveWords.selfieSystem : LiveWords.system
        let style = mode.ask(question, coachGoal: coachGoal)
        let prompt = unprompted ? prompt : prompt + style   // the mode's style rides on the question
        let camera = camera
        // The photo is already read if the frame still matches and the prompt is the usual one.
        let canUsePrefill = withPhoto && !unprompted && !first && longSide == 512 && engine.canPrefill
        let pendingPrefill = canUsePrefill ? prefillTask : nil
        if !canUsePrefill { prefilled = nil }
        modelBusy = true
        // Everything from here runs off the main thread: the grab, the copy, the resize and the model,
        // so the preview and the orb never wait on it.
        Task.detached(priority: .userInitiated) { [weak self] in
            // A stale camera gets restarted by current(); give it up to ~1.5 s to come back before giving up.
            var grabbed = withPhoto ? camera.current() : LiveCallController.noFrame
            // The opening look waits up to ~6 s for the camera's first frame (11/1 logs: it gave up at 4.9 s).
            for _ in 0..<(first ? 20 : 5) where grabbed == nil && withPhoto {
                try? await Task.sleep(nanoseconds: 300_000_000)
                grabbed = camera.current()
            }
            guard let frame = grabbed else {
                await MainActor.run {
                    self?.modelBusy = false
                    if !unprompted { self?.sayPart(.own(LiveCamWords.cameraPaused), turn: my) }
                    self?.answerDone = true
                }
                return
            }
            let thumb = LiveCamera.thumb(frame)
            // Same view as last answer: the same words are right, so no repeat check (it cost ~1 s per answer, 11/1 test).
            if let lastView, LiveProactive.difference(thumb, lastView) < 10 { guardRepeat.checked = true }
            let clock = FirstSentence()
            let onText: (String) -> Bool = { text in
                guard !unprompted else { return box.isAlive }
                // 11/1: it kept answering with its last answer word for word. Hold the first sentence until it is
                // complete; if it is the last answer again, stop and ask once more with the photo and no history.
                if !guardRepeat.checked, let lastAnswer {
                    guard let end = text.firstIndex(where: { ".!?".contains($0) }), text.distance(from: text.startIndex, to: end) > 12
                    else { return box.isAlive }
                    guardRepeat.checked = true
                    let first = String(text[...end])
                    let lastFirst = lastAnswer.firstIndex(where: { ".!?".contains($0) }).map { String(lastAnswer[...$0]) } ?? lastAnswer
                    if LiveWords.isRepeat(first, of: lastFirst) { guardRepeat.repeated = true; return false }
                }
                let s = box.feed(text)
                if !s.isEmpty {
                    clock.mark()
                    DispatchQueue.main.async { MainActor.assumeIsolated { s.forEach { self?.sayPart(.content($0), turn: my) } } }
                }
                return box.isAlive
            }
            await pendingPrefill?.value
            let ready: Prefilled? = canUsePrefill ? await MainActor.run { () -> Prefilled? in
                let p = self?.prefilled; self?.prefilled = nil; return p
            } : nil
            var usedPrefill = false
            var answer: LiveVisionEngine.Answer?
            #if DEBUG
            let faking = LiveCamTest.fakeAnswer != nil && question != nil
            #else
            let faking = false
            #endif
            if !faking, let ready, ready.system == system, Date().timeIntervalSince(ready.at) < 20,
               LiveProactive.difference(thumb, ready.thumb) < 15 {
                answer = engine.answer(question: prompt, maxTokens: mode.maxTokens, onText: onText)
                usedPrefill = answer != nil
            }
            if !faking, answer == nil && !guardRepeat.repeated {
                answer = engine.respond(system: system, question: prompt, image: withPhoto ? frame : nil, longSide: longSide,
                                        maxTokens: mode.maxTokens, onText: onText)
            }
            var retried = false
            if !faking, guardRepeat.repeated, let q = question, box.isAlive {
                // Same words as last time: a fresh look at a fresh frame, nothing it said before in the prompt.
                retried = true
                if withPhoto {
                    answer = engine.respond(system: system, question: LiveWords.question(q, history: []) + style, image: camera.current() ?? frame,
                                            longSide: longSide, maxTokens: mode.maxTokens, onText: onText)
                } else {
                    answer = engine.respond(system: system, question: LiveWords.chatQuestion(q, history: []), image: nil,
                                            longSide: longSide, maxTokens: mode.maxTokens, onText: onText)
                }
            }
            let repeatRetried = retried
            let prefillUsed = usedPrefill
            #if DEBUG
            if let fake = LiveCamTest.fakeAnswer, question != nil {
                // Simulator stand-in for the model (RTCAM_FAKE_LIVE_ANSWER), streamed like the real thing.
                answer = LiveVisionEngine.Answer(text: fake, firstTokenMs: 0, encodeMs: 0, totalMs: 0, tokens: 0)
                _ = onText(fake)
            }
            #endif
            await MainActor.run {
                self?.modelBusy = false
                guard let self, self.running, self.turn == my else { return }
                let tail = unprompted ? [] : box.feed(box.lastText, final: true)
                if !tail.isEmpty { clock.mark() }
                let firstAt = clock.at
                tail.forEach { self.sayPart(.content($0), turn: my) }
                if let firstAt { self.recentFirstSentence = firstAt.timeIntervalSince(asked) }
                if withPhoto, let e = answer?.encodeMs, e > 0 { self.recentEncodeMs = e }
                let said = LiveSentenceStream.cleaned(answer?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !unprompted, !said.isEmpty {
                    // Every sentence was one it had already said: say so briefly instead of going silent.
                    if self.tally.turn == my, self.tally.said == 0, self.tally.dropped > 0 { self.sayPart(.own(LiveCamWords.sameAsBefore), turn: my) }
                    // The one help offer of the visit comes after the opening look (Matt 11/6), never from the model.
                    else if first, !self.sayGuard.helpOffered { self.sayPart(.own(LiveCamWords.helpOffer), turn: my) }
                }
                self.log(["event": unprompted ? "watch_answer" : "answer", "text": said,
                          "thermal": ProcessInfo.processInfo.thermalState.rawValue,
                          "question": question ?? (first ? "(opening look)" : ""),
                          "first_sentence_s": firstAt.map { $0.timeIntervalSince(asked) } ?? -1,
                          "first_token_ms": answer?.firstTokenMs ?? -1, "encode_ms": answer?.encodeMs ?? -1,
                          "total_ms": answer?.totalMs ?? -1, "tokens": answer?.tokens ?? 0, "confidence": ((answer?.confidence ?? 1) * 100).rounded() / 100, "lowest": ((answer?.lowest ?? 1) * 100).rounded() / 100, "photo_px": withPhoto ? longSide : 0,
                          "used_prefill": prefillUsed, "repeat_retried": repeatRetried])
                self.current = nil
                if unprompted && self.inventoryLook {
                    // Novelty only (11/2 Matt): everything listed is remembered; only a thing never named gets a line.
                    self.inventoryLook = false
                    self.answerDone = true
                    self.watch.described(thumb)
                    let items = LiveWords.items(said), fresh = self.memory.newThings(items)
                    self.memory.noteThings(items)
                    let talking = self.phase != .listening || self.listener.hearingSomething
                    self.log(["event": "watch_decision", "listed": said, "new": fresh.joined(separator: ", "),
                              "decision": fresh.isEmpty ? "silent: nothing new" : talking ? "silent: person talking" : "spoke"])
                    if !fresh.isEmpty, !talking {
                        // 11/2 Matt "be really cautious": each new thing is checked yes/no on the same photo first;
                        // anything it can't confirm is never said.
                        self.lastNovelty = Date()
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            let ok = await self.confirm(Array(fresh.prefix(3)), in: frame).filter { $0.value }.map(\.key)
                            self.log(["event": "confirm", "things": fresh.joined(separator: ", "), "confirmed": ok.joined(separator: ", ")])
                            guard !ok.isEmpty, self.running, self.phase == .listening, !self.listener.hearingSomething else { return }
                            let things = fresh.filter(ok.contains)
                            // Matt 11/6: the help offer only once a visit; after it, just "I see a boat."
                            let format = self.sayGuard.newThingFormat
                            let line = String(format: format, LiveWords.newThings(things))
                            guard self.sayGuard.vet(line) != nil else { self.log(["event": "dropped_repeat", "text": line]); return }
                            self.watch.commented(at: Date())
                            self.memory.noteSeen(line)
                            self.listener.stopListening()
                            self.speakAll(.withContent(format, LiveWords.newThings(things)))
                        }
                    }
                    return
                }
                if unprompted {
                    self.answerDone = true
                    // Looked either way: wait for the view to change again before the next look, so a
                    // "nothing new" or a repeat doesn't run the model every couple of seconds.
                    self.watch.described(thumb)
                    // Only something new, never over the person, never a repeat.
                    let verdict: String
                    if LiveWords.isNothingNew(said) { verdict = "silent: nothing new" }
                    else if LiveWords.isRepeat(said, of: lastSeen) || LiveWords.overlapsSaid(said, said: self.memory.said) { verdict = "silent: already said" }
                    else if self.sayGuard.vet(said) == nil { verdict = "silent: repeat guard" }
                    else if self.phase != .listening || self.listener.hearingSomething { verdict = "silent: person talking" }
                    else { verdict = "spoke" }
                    self.log(["event": "watch_decision", "decision": verdict, "view_change": (self.watch.lastDifference * 10).rounded() / 10])
                    if verdict == "spoke" {
                        self.watch.commented(at: Date())
                        self.watch.described(thumb)
                        self.memory.noteSeen(said)
                        self.listener.stopListening()
                        self.speakAll(content: self.sayGuard.vet(said) ?? said)
                    }
                    return
                }
                // Calibrated on the 11/2 limits test: a guessed answer has unsure words in it.
                // 11/3 Matt: in Funny mode the yellow "Probably guessing" sign and "I'm not fully sure" came after a joke.
                // A joke always reads as unsure, so Funny skips the guess sign and the double-check.
                if mode == .funny {
                } else if let a = answer, !said.isEmpty, a.confidence < LiveWords.unsureMean || a.lowest < LiveWords.unsureLowest,
                   self.notice == nil {
                    self.showNotice("Probably guessing — double-check")
                    if withPhoto && !general { self.sayPart(.own(LiveCamWords.notFullySure), turn: my) }   // say it, not just show it (11/2)
                } else if withPhoto, !general, question != nil, !said.isEmpty, !LiveWords.isNothingNew(said), !LiveWords.saysNotThere(said) {
                    // 11/2 double-check: every thing the answer names is asked yes/no on the same photo; one it can't
                    // confirm gets taken back out loud ("one screen" was the dark doorway, said at 0.88 sure).
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let things = await self.thingsNamed(in: said)
                        guard !things.isEmpty else { return }
                        let res = await self.confirm(things, in: frame), bad = things.filter { res[$0] == false }
                        self.log(["event": "confirm", "things": things.joined(separator: ", "), "unconfirmed": bad.joined(separator: ", ")])
                        guard let b = bad.first, self.running, self.turn == my else { return }
                        self.showNotice("Couldn't confirm: \(bad.joined(separator: ", "))")
                        self.sayPart(.withContent(LiveCamWords.takeBack, b), turn: my)
                    }
                }
                if said.isEmpty { self.sayPart(.own(LiveCamWords.lostAnswer), turn: my) }
                else if let question { self.memory.note(question: question, answer: said) } else { self.memory.noteSeen(said) }
                self.watch.described(thumb)
                self.answerDone = true
                if withPhoto && !said.isEmpty { self.describedOnce = true }
                if !self.voice.isBusy { self.wentQuiet() }
            }
        }
    }

    /// Yes/no on the same photo for each thing (512 px, a few tokens each).
    private func confirm(_ things: [String], in frame: CGImage) async -> [String: Bool] {
        guard let engine else { return [:] }
        var out: [String: Bool] = [:]
        for t in things {
            let a = await Task.detached(priority: .utility) {
                engine.respond(system: LiveWords.system, question: LiveWords.confirmAsk(t), image: frame, longSide: 512, maxTokens: 3)
            }.value
            out[t] = (a?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("yes")
        }
        return out
    }
    /// The physical things an answer names (text only, no photo), people and clothes left out, at most three.
    private func thingsNamed(in answer: String) async -> [String] {
        guard let engine else { return [] }
        let a = await Task.detached(priority: .utility) {
            engine.respond(system: "You pull out object names.", question: LiveWords.extractAsk(answer), image: nil, longSide: 512, maxTokens: 30)
        }.value
        return Array(LiveWords.items(a?.text ?? "").filter { LiveWords.contentWords($0).isDisjoint(with: LiveWords.personWords.union(LiveWords.selfWords)) }.prefix(3))
    }

    /// The question being answered is about Live Cam itself, so it may say what it is.
    private var askedAboutMe = false

    /// Part of an answer. The model's sentences are cleaned (LiveWords.spoken); the app's own lines are said as written.
    private func sayPart(_ line: LiveLine, turn my: Int) {
        guard running, turn == my else { return }
        var line = line
        if case let .content(s) = line {
            guard let cleaned = LiveWords.spoken(s, aboutMe: askedAboutMe) else { return }
            if tally.turn != my { tally = (my, 0, 0); sayGuard.beginTurn() }
            // Matt 11/6: "it should not repeat phrases": a sentence repeated in this answer, a looping one, a second
            // help offer. An answer to a question is never dropped for having been said before (review 11/6).
            guard let vetted = sayGuard.vet(cleaned, prompted: true) else {
                tally.dropped += 1
                log(["event": "dropped_repeat", "text": cleaned])
                return
            }
            tally.said += 1
            line = .content(vetted)
        }
        phase = .speaking
        listener.watchForBargeIn(true)
        say(line)
    }

    // MARK: The light watch

    private func startWatch() {
        guard watchTask == nil else { return }
        watchTask = Task { @MainActor [weak self] in
            while let self, self.running, !Task.isCancelled {
                // About every 2.5 s, slower on a slow phone.
                let every = max(1.5, (self.recentFirstSentence ?? 1) * 1.2)   // 11/1 Matt: too slow calling the scene
                try? await Task.sleep(nanoseconds: UInt64(every * 1e9))
                guard self.running, self.phase == .listening, self.current == nil,
                      !self.listener.hearingSomething else { continue }
                let cam = self.camera
                guard let thumb = await Task.detached(priority: .utility, operation: { () -> [UInt8]? in
                          guard let f = cam.current() else { return nil }
                          return LiveCamera.thumb(f)
                      }).value,
                      self.running, self.phase == .listening, self.current == nil else { continue }
                let quiet = Date().timeIntervalSince(self.listener.lastChange) > 2
                // Every mode is a companion, not a commentator (11/2 Normal; 11/3 Matt in Funny: "Now I see a bald man with glasses"
                // came out unasked and sounded like it was hearing itself). No "Now I see", just a check-in after a long quiet.
                do {
                    if quiet, self.watch.shouldCheckIn(at: Date(), quietSince: max(self.lastHeardAt, self.lastSpokeEnd)),
                       // Matt 11/6: the lines take turns (none twice until all are used), and once help was offered
                       // only the ones that don't offer it again.
                       let line = self.checkInTurns.next(from: self.sayGuard.helpOffered
                                                              ? LiveWords.checkIns.filter { !LiveWords.isHelpOffer($0) } : LiveWords.checkIns) {
                        self.log(["event": "watch_fired", "why": "check in"])
                        self.watch.commented(at: Date())
                        self.memory.noteSeen(line)
                        self.listener.stopListening()
                        self.speakAll(own: line)
                    } else if Date().timeIntervalSince(self.lastNovelty) >= 20, Date().timeIntervalSince(self.lastHeardAt) >= 8,
                              self.answerDone,
                              self.watch.shouldLook(thumb: thumb, at: Date(), quiet: quiet) {
                        // The view changed: list what's there, quietly; only a never-named thing is said (11/2 Matt).
                        self.log(["event": "watch_fired", "why": "inventory", "view_change": (self.watch.lastDifference * 10).rounded() / 10])
                        self.inventoryLook = true
                        self.look(prompt: LiveWords.inventory, unprompted: true)
                    } else {
                        self.startPrefill(always: true)
                    }
                }
            }
        }
    }
}

private final class FirstSentence: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date?
    func mark() { lock.lock(); if t == nil { t = Date() }; lock.unlock() }
    var at: Date? { lock.lock(); defer { lock.unlock() }; return t }
}
