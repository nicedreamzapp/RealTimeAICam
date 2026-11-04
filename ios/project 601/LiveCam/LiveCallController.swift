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
    /// The last question heard (in the person's words), shown above the answer.
    @Published private(set) var heardText = ""

    let camera = LiveCamera()
    let listener = LiveListener()
    let voice: LiveVoiceOutput = LiveAppleVoice()
    private var engine: LiveVisionEngine?
    private var preload: Task<LiveVisionEngine?, Never>?
    /// Test builds: a typed question instead of the mic (LiveCamTest).
    var typedOnly = false
    /// A no-photo turn still runs through look(); this stands in for the frame and is never sent.
    nonisolated static let noFrame: CGImage? = {
        let c = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        return c?.makeImage()
    }()

    private var memory = LiveMemory()
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
        UIApplication.shared.isIdleTimerDisabled = true
        watch.enabled = proactiveOn
        LiveCamTest.beginSession()
        openedAt = Date()
        // Nothing else in the app talks while Live Cam is open.
        SpeechManager.shared.resetSpeechState()
        let level = LiveCamModel.level
        log(["event": "open", "test": LiveCamTest.active, "level": level.rawValue,
             "thermal": ProcessInfo.processInfo.thermalState.rawValue])
        configureTest()
        voice.onStart = { [weak self] shown, english in
            guard let self else { return }
            self.caption = shown
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
        listener.onBargeIn = { [weak self] in self?.bargeIn() }
        listener.onLevel = { [weak self] l in self?.micLevel = l }
        listener.onPartial = { [weak self] t in self?.log(["event": "partial", "text": t]); self?.startPrefill() }
        Task {
            // What's this? holds its own copy of the model: let it go before Live Cam loads one (never two at once).
            await OnDeviceVisionNarrator.shared.releaseEngine()
            // Load the model while the camera, mic and voice start.
            preload = Task.detached(priority: .userInitiated) { try? LiveVisionEngine(level: level) }
            if !typedOnly {
                guard await LiveCamera.requestAccess() else {
                    fail("Live Cam needs the camera. Allow it in Settings, then open Live Cam again."); return
                }
            }
            camera.onEvent = { [weak self] o in DispatchQueue.main.async { MainActor.assumeIsolated { self?.log(o) } } }
            camera.start()
            if !typedOnly {
                if LiveListener.willAskPermission {
                    // The first time: say why before iOS asks (blind users hear the reason, then the two prompts).
                    phase = .speaking
                    caption = LiveCamWords.permissionLine
                    voice.say(LiveCamWords.permissionLine)
                    while voice.isBusy { try? await Task.sleep(nanoseconds: 150_000_000) }
                }
                if let f = await listener.start() {
                    fail(f == .notAllowed ? LiveCamWords.notAllowed : LiveCamWords.noOfflineSpeech)
                    return
                }
            }
            await prepareModel(level)
        }
    }

    func end() {
        guard running else { return }
        running = false
        watchTask?.cancel()
        current?.cancel(); current = nil
        voice.onQuiet = nil
        voice.stop()
        listener.shutdown()
        camera.stop()
        // The model is let go (What's this? loads its own copy when it is next used).
        preload?.cancel(); preload = nil
        engine = nil
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .ended
        log(["event": "ended"])
        onEnd?()
    }

    private func fail(_ why: String) {
        phase = .failed
        caption = why
        log(["event": "failed", "why": why])
        voice.say(why)
    }

    private func prepareModel(_ level: ModelLevel) async {
        log(["event": "level", "level": level.rawValue])
        phase = .loading
        let t0 = Date()
        if let p = preload { engine = await p.value }
        preload = nil
        guard running else { engine = nil; return }
        if engine == nil, level != .balanced {
            // The picked level wouldn't load: the bundled Balanced, always on the phone.
            log(["event": "level_fallback", "from": level.rawValue])
            engine = await Task.detached(priority: .userInitiated) { try? LiveVisionEngine(level: .balanced) }.value
        }
        guard engine != nil else {
            fail("I couldn't start the vision model. Go back and try Live Cam again.")
            log(["event": "load failed"])
            return
        }
        log(["event": "loaded", "seconds": Date().timeIntervalSince(t0)])
        guard running else { return }
        // Greet like a friend, then wait for cues (11/2 Matt): it only looks when asked.
        phase = .speaking
        listener.watchForBargeIn(true)
        describedOnce = true
        memory = LiveMemory()
        voice.say(LiveWords.greeting)
        if !typedOnly { look(prompt: LiveWords.openingLook, unprompted: false, first: true) }   // what's around, once (11/2 Matt)
        else { answerDone = true }
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
        if !micMuted, !typedOnly { listener.listen() }
        if !typedOnly { startWatch() }
    }

    private func micMutedChanged() {
        log(["event": "mic", "muted": micMuted])
        if micMuted { listener.stopListening() } else if phase == .listening { listener.listen() }
    }

    /// Talked over: stop now and take the new question (first words kept).
    /// The start of a sentence that was cut off at a pause: the rest gets joined on (11/1 phone test: "Tell me everything
    /// you see… in this room" ended at the pause, the rest counted as an interruption and the leftover was dropped).
    private var cutOff: (text: String, at: Date)?
    private var lastQuestion = ""

    func bargeIn() {
        guard running, !micMuted, phase == .speaking || phase == .thinking else { return }
        // Still thinking and they kept talking right after: they weren't done, so keep what they said so far.
        if phase == .thinking, let e = questionEndedAt, Date().timeIntervalSince(e) < 2.5, !lastQuestion.isEmpty {
            cutOff = (lastQuestion, Date())
        }
        log(["event": "barge_in", "phase": "\(phase)", "kept_start": cutOff?.text ?? ""])
        stopTalking()
        phase = .listening
        listener.listen(replay: true)
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
            speakAll("Sorry, say that again?"); return
        case .answer:
            entry["decision"] = "answered"; log(entry)
        }
        watch.personSpoke()
        lastQuestion = q
        notice = nil
        // It only keeps the last couple of exchanges (90 s): "what did I ask first" is past its memory, say so.
        if LiveWords.reachesBack(q) {   // it keeps only the last two exchanges, so reaching back is past it (run 2)
            showNotice("Lost track — ask the whole question again")
            speakAll("I lost track of that part. Ask me the whole question again?")
            return
        }
        if LiveWords.pastItsLeague(q) { showNotice("Past what I can do offline — double-check this one") }
        askedAboutMe = LiveWords.isAboutLiveCam(q)
        log(["event": "question", "text": q, "ended": endedAt.timeIntervalSince1970])
        switch LiveWords.turn(q) {
        case .end:
            voice.say("Okay, bye for now.")
            Task { @MainActor in try? await Task.sleep(nanoseconds: 1_500_000_000); self.end() }
        case .stopSaying:
            questionEndedAt = endedAt
            speakAll("Got it.")
        case .hush:
            stopTalking()
            listen()
        case let .mode(m):
            questionEndedAt = endedAt
            let rest = LiveWords.modeRest(q)
            if m == .coach, let goal = rest.flatMap(LiveWords.coachGoal) {
                // "Coach me on my jump shot": the goal is set, no need to ask for it.
                setMode(m, say: "Coach mode on. Let's work on \(goal). Show me, or ask me anything about it.", goal: goal)
            } else if m == .analyze, rest != nil {
                // "Analyze the forces on this shelf": switch AND answer it.
                setMode(m, quiet: true)
                ask(q, endedAt: endedAt)
            } else {
                setMode(m)
            }
        case .repeatLast:
            questionEndedAt = endedAt
            speakAll(memory.lastAnswer ?? "I haven't said anything yet.")
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
                speakAll("Got it, \(goal). Show me what you're doing, or ask me anything about it.")
                return
            }
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
            speakAll("Flip the camera to face you and I'll take a look.")
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

    /// `say`: what to say instead of the usual confirm; `quiet`: say nothing (the answer follows). `goal`: Coach's topic.
    func setMode(_ m: LiveMode, tapped: Bool = false, say: String? = nil, quiet: Bool = false, goal: String? = nil) {
        mode = m
        coachGoal = m == .coach ? goal : nil
        awaitingCoachGoal = m == .coach && goal == nil
        log(["event": "mode", "mode": m.rawValue, "tapped": tapped, "goal": goal ?? ""])
        guard running else { return }
        current?.cancel(); current = nil
        listener.stopListening()
        if !quiet { speakAll(say ?? m.confirm) }
    }

    /// The mode button: Normal → Funny → Analyze → Coach → Normal.
    func nextMode() {
        let all = LiveMode.allCases
        setMode(all[(all.firstIndex(of: mode)! + 1) % all.count], tapped: true)
    }

    private func speakAll(_ text: String) {
        turn += 1
        answerDone = true
        phase = .speaking
        listener.watchForBargeIn(true)
        voice.say(text)
    }

    // MARK: Looking

    /// Frame now + prompt → the model; sentences are spoken as they come. `unprompted` lines are
    /// only spoken if they say something new.
    private func look(prompt: String, unprompted: Bool, question: String? = nil, first: Bool = false, withPhoto: Bool = true,
                      general: Bool = false) {
        guard let engine else {
            if !unprompted { speakAll("I'm still getting ready. Ask me again in a second.") }
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
                voice.say(a)
                phase = .speaking
            }
        }
        // 11/1: the voice keeps working with the phone locked or another app in front (background audio), but iOS
        // never lets the camera run there. Say so instead of answering about the last picture it had.
        if withPhoto, UIApplication.shared.applicationState != .active {
            log(["event": "camera_unavailable", "app_state": UIApplication.shared.applicationState.rawValue])
            answerDone = true
            if !unprompted { speakAll("I can't see while the phone is locked or another app is open. Open RealTime AI Cam again and ask me.") }
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
                    if !unprompted { self?.sayPart("My camera paused, I'm restarting it. Ask me again in a second.", turn: my) }
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
                    DispatchQueue.main.async { MainActor.assumeIsolated { s.forEach { self?.sayPart($0, turn: my) } } }
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
                tail.forEach { self.sayPart($0, turn: my) }
                if let firstAt { self.recentFirstSentence = firstAt.timeIntervalSince(asked) }
                if withPhoto, let e = answer?.encodeMs, e > 0 { self.recentEncodeMs = e }
                let said = LiveSentenceStream.cleaned(answer?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
                            let line = LiveWords.newThingLine(fresh.filter(ok.contains))
                            self.watch.commented(at: Date())
                            self.memory.noteSeen(line)
                            self.listener.stopListening()
                            self.speakAll(line)
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
                    else if self.phase != .listening || self.listener.hearingSomething { verdict = "silent: person talking" }
                    else { verdict = "spoke" }
                    self.log(["event": "watch_decision", "decision": verdict, "view_change": (self.watch.lastDifference * 10).rounded() / 10])
                    if verdict == "spoke" {
                        self.watch.commented(at: Date())
                        self.watch.described(thumb)
                        self.memory.noteSeen(said)
                        self.listener.stopListening()
                        self.speakAll(said)
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
                    if withPhoto && !general { self.sayPart("I'm not fully sure on that one.", turn: my) }   // say it, not just show it (11/2)
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
                        self.sayPart("Actually, I'm not sure about the \(b).", turn: my)
                    }
                }
                if said.isEmpty { self.sayPart("Sorry, I lost that. Ask me again?", turn: my) }
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

    private func sayPart(_ s: String, turn my: Int) {
        guard running, turn == my, let s = LiveWords.spoken(s, aboutMe: askedAboutMe) else { return }
        phase = .speaking
        listener.watchForBargeIn(true)
        voice.say(s)
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
                       let line = LiveWords.checkIns.filter({ $0 != self.memory.said.last }).randomElement() {
                        self.log(["event": "watch_fired", "why": "check in"])
                        self.watch.commented(at: Date())
                        self.memory.noteSeen(line)
                        self.listener.stopListening()
                        self.speakAll(line)
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
