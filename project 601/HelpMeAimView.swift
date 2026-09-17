import AVFoundation
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
    private var announcementToken = 0
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

    var isBusy: Bool { synth.isSpeaking || announcementPending }

    func warmRoute() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audio.setActive(true)
        try? audio.overrideOutputAudioPort(.speaker)
    }

    func say(_ text: String) {
        let line = AimPhrases.capitalized(text)
        if usesVoiceOver {
            announcementPending = true
            announcementToken += 1
            let token = announcementToken
            UIAccessibility.post(notification: .announcement, argument: line)
            // If VoiceOver drops the announcement it never reports back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, announcementToken == token else { return }
                announcementPending = false
            }
            return
        }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.52
        utterance.volume = 1.0
        synth.speak(utterance)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        announcementPending = false
    }

    @objc private func announcementFinished() {
        announcementPending = false
    }
}

// MARK: Listening for the word

/// Hears one word or short phrase, on the phone only, and stops by itself
/// after a short silence.
@MainActor
final class AimWordListener: ObservableObject {
    enum Outcome { case heard(String), notAllowed, unavailable }

    @Published private(set) var isRunning = false
    @Published private(set) var transcript = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastChange = Date()
    private var startedAt = Date()
    private var watchdog: Task<Void, Never>?
    private var finish: ((Outcome) -> Void)?

    func start(_ done: @escaping (Outcome) -> Void) async {
        guard !isRunning else { return }
        guard await Self.authorize() else { done(.notAllowed); return }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            done(.unavailable); return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Offline only: the word never leaves the phone.
        req.requiresOnDeviceRecognition = true
        req.contextualStrings = ["keys", "wallet", "phone", "cup", "dog", "cat", "painting", "remote", "glasses", "door"]
        request = req
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try s.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { done(.unavailable); return }

        transcript = ""
        finish = done
        let node = engine.inputNode
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { [weak req] buf, _ in
            req?.append(buf)
        }
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                if let text, text != self.transcript {
                    self.transcript = text
                    self.lastChange = Date()
                }
                if final || failed { self.stop(deliver: true) }
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            cleanup()
            done(.unavailable)
            return
        }
        isRunning = true
        startedAt = Date()
        lastChange = Date()
        watchdog = Task { @MainActor [weak self] in
            while let self, self.isRunning {
                try? await Task.sleep(nanoseconds: 150_000_000)
                let now = Date()
                let quiet = now.timeIntervalSince(self.lastChange)
                let total = now.timeIntervalSince(self.startedAt)
                if (!self.transcript.isEmpty && quiet > 1.3) || total > 7 || (self.transcript.isEmpty && total > 5) {
                    self.stop(deliver: true)
                }
            }
        }
    }

    /// Stop listening. `deliver` false means the result is thrown away.
    func stop(deliver: Bool) {
        guard isRunning else { return }
        isRunning = false
        let heard = transcript
        let done = finish
        finish = nil
        cleanup()
        if deliver { done?(.heard(heard)) }
    }

    private func cleanup() {
        watchdog?.cancel(); watchdog = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel(); task = nil; request = nil
        // Hand the audio back to the loudspeaker for the steering voice.
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? s.setActive(true)
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

    let voice = AimVoice()
    let listener = AimWordListener()
    let analyzer = AimFrameAnalyzer()
    weak var camera: AimCameraView?

    private var coach: AimCoach?
    /// Other things YOLOE saw in the last few frames.
    private var recentOthers: [[AimElsewhere.Seen]] = []
    private var countdownTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var classNames: [String]?
    private var classIndex: [String: [Int32]] = [:]
    private var finder: AimObjectFinder?
    private var paused = false
    private let tick = UIImpactFeedbackGenerator(style: .light)
    private let beat = UIImpactFeedbackGenerator(style: .medium)
    private let notify = UINotificationFeedbackGenerator()

    init() {
        analyzer.onObservation = { [weak self] obs in
            MainActor.assumeIsolated { self?.handle(obs) }
        }
    }

    func setVoice(_ identifier: String) {
        voice.voiceIdentifier = identifier
    }

    // MARK: Choices

    func chooseFace() { begin(.face) }
    func choosePage() { begin(.page) }

    func chooseSomethingElse() {
        phase = .asking
        statusText = "What are you looking for?"
        voice.warmRoute()
        sayAfterVoiceOver(AimPhrases.askWhat)
    }

    func backToChoices() {
        stopAiming()
        listener.stop(deliver: false)
        phase = .choosing
        statusText = ""
        subject = nil
    }

    func listen() {
        if listener.isRunning {
            listener.stop(deliver: true)
            return
        }
        voice.stop()
        tick.impactOccurred()
        let listener = listener
        let handle: (AimWordListener.Outcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case let .heard(text): submit(text)
            case .notAllowed:
                voice.say("I can't use the microphone. Allow it in Settings, or type the word.")
            case .unavailable:
                voice.say("Offline listening isn't available on this phone. Type the word instead.")
            }
        }
        Task { await listener.start(handle) }
    }

    func submit(_ text: String) {
        let names = vocabulary()
        guard let match = AimVocabulary.match(text, index: classIndex), !names.isEmpty else {
            let said = AimVocabulary.normalize(text)
            statusText = AimPhrases.capitalized(AimPhrases.cantLookFor(said))
            voice.say(AimPhrases.cantLookFor(said))
            return
        }
        begin(.object(match))
    }

    private func vocabulary() -> [String] {
        if let classNames { return classNames }
        let names = AimObjectFinder.loadClassNames()
        classNames = names
        classIndex = AimVocabulary.index(names)
        return names
    }

    // MARK: Aiming

    private func begin(_ newSubject: AimSubject) {
        subject = newSubject
        phase = .aiming
        paused = false
        coach = AimCoach(subject: newSubject)
        coach?.reset(now: Date())
        recentOthers = []
        statusText = "Looking for \(newSubject.spokenName)"
        if newSubject != .face { cameraPosition = .back }
        voice.warmRoute()
        sayAfterVoiceOver(AimPhrases.intro(for: newSubject))
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
                    voice.say("The object finder didn't load. Try Face or Picture or Page.")
                    return
                }
                analyzer.configure(kind: .object, classIDs: Set(match.classIDs), finder: finder)
                coach?.reset(now: Date())
                if !paused { analyzer.setPaused(false) }
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
        statusText = "Taking the picture"
        let snapshot = analyzer.snapshot()
        let framing = subject.framing
        let subjectName = subject.spokenName
        camera.captureBurst(count: Self.burstCount, interval: Self.burstInterval) { [weak self] frames in
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
            statusText = "Picking the best one"
            Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    AimShotProcessor.process(frames, snapshot: snapshot, framing: framing, subjectName: subjectName)
                }.value
                guard let self, phase == .capturing else { return }
                lastPhoto = result.image
                phase = .taken
                statusText = "Picture taken"
                #if HELP_ME_AIM_SHOT_LOG
                if let keep = result.keep { TestShotLog.write(keep) }
                #endif
                // Exactly one photo per burst reaches the library.
                guard let jpeg = result.keep?.photo else {
                    voice.say(AimPhrases.captureFailed)
                    statusText = AimPhrases.capitalized(AimPhrases.captureFailed)
                    return
                }
                Self.save(jpeg) { [weak self] saved in
                    guard let self else { return }
                    let line = AimPhrases.pictureTaken + (saved ? AimPhrases.savedSuffix : AimPhrases.notSavedSuffix)
                    statusText = AimPhrases.capitalized(line)
                    voice.say(line)
                }
            }
        }
    }

    static let burstCount = 5
    static let burstInterval: TimeInterval = 0.18

    func takeAnother() {
        guard let subject else { backToChoices(); return }
        lastPhoto = nil
        begin(subject)
    }

    private static func save(_ data: Data, done: @escaping @MainActor (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { done(false) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { ok, _ in
                DispatchQueue.main.async { done(ok) }
            })
        }
    }

    // MARK: Camera controls

    func toggleCamera() {
        cameraPosition = cameraPosition == .back ? .front : .back
        setTorch(false)
        coach?.reset(now: Date())
        voice.say(cameraPosition == .front ? "front camera" : "back camera")
    }

    func toggleTorch() {
        setTorch(!torchOn)
        voice.say(torchOn ? "flashlight on" : "flashlight off")
    }

    private func setTorch(_ on: Bool) {
        let allowed = on && cameraPosition == .back
        camera?.setTorch(allowed)
        torchOn = allowed
    }

    // MARK: Lifecycle

    private func stopAiming() {
        countdownTask?.cancel(); countdownTask = nil
        countdownWord = nil
        analyzer.setPaused(true)
        setTorch(false)
        voice.stop()
    }

    /// Leaving for the background (or Control Center): torch off, camera
    /// off, countdown cancelled. The screen and the subject are kept.
    func pause() {
        paused = true
        stopAiming()
        listener.stop(deliver: false)
        camera?.stop()
        if phase == .capturing { phase = .aiming }
    }

    /// Back in the app: pick the steering up where it was.
    func resume() {
        guard paused else { return }
        paused = false
        guard phase == .aiming, let subject else { return }
        camera?.start(position: cameraPosition)
        coach?.reset(now: Date())
        voice.warmRoute()
        sayAfterVoiceOver("Still looking for \(subject.spokenName)")
        switch subject {
        case .object: if finder != nil { analyzer.setPaused(false) }
        default: analyzer.setPaused(false)
        }
    }

    /// Leaving the screen: everything off and the model released.
    func shutdown() {
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
        .onAppear { controller.setVoice(voiceIdentifier) }
        .onDisappear { controller.shutdown() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.resume() } else { controller.pause() }
        }
    }

    // MARK: Choices

    private var choices: some View {
        VStack(spacing: 18) {
            topBar(title: "Help Me Aim", back: {
                controller.shutdown()
                onBack()
            }, backLabel: "Back to home")
            Text("What do you want a picture of?")
                .font(.title2.weight(.semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            AimBigButton(emoji: "🙂", title: "Face", color: .pink,
                         hint: "Finds faces and talks you into the shot, then takes the picture") {
                controller.chooseFace()
            }
            AimBigButton(emoji: "🖼️", title: "Picture or Page", color: .blue,
                         hint: "Finds a page, a sign or a picture on the wall and gets all of it in the shot") {
                controller.choosePage()
            }
            AimBigButton(emoji: "🔎", title: "Something Else", color: .orange,
                         hint: "Say what you're looking for, like keys or a cup") {
                controller.chooseSomethingElse()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: Asking

    private var asking: some View {
        VStack(spacing: 18) {
            topBar(title: "Something Else", back: { controller.backToChoices() }, backLabel: "Back to choices")
            Text("What are you looking for?")
                .font(.title2.weight(.semibold))
                .foregroundColor(.white)
                .accessibilityAddTraits(.isHeader)
            AimListenButton(listener: controller.listener) { controller.listen() }
            if !controller.statusText.isEmpty, controller.statusText != "What are you looking for?" {
                Text(controller.statusText)
                    .font(.headline)
                    .foregroundColor(.yellow)
                    .multilineTextAlignment(.center)
                    .accessibilityHidden(true)
            }
            HStack {
                TextField("Or type it", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { controller.submit(typed) }
                    .accessibilityLabel("Or type what you're looking for")
                Button("Find") { controller.submit(typed) }
                    .buttonStyle(.borderedProminent)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: Aiming

    private var aiming: some View {
        ZStack {
            AimCameraPreview(controller: controller)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { controller.shootNow() }
                .accessibilityElement()
                .accessibilityLabel("Camera, looking for \(controller.subject?.spokenName ?? "your subject")")
                .accessibilityHint("Double tap to take the picture now")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { controller.shootNow() }
                .accessibilityFocused($cameraFocused)

            VStack {
                HStack(spacing: 12) {
                    smallButton("Back", system: "chevron.left", label: "Back to choices") {
                        controller.backToChoices()
                    }
                    Spacer()
                    if controller.subject == .face {
                        smallButton(nil, system: "arrow.triangle.2.circlepath.camera",
                                    label: controller.cameraPosition == .back ? "Switch to front camera" : "Switch to back camera") {
                            controller.toggleCamera()
                        }
                    }
                    if controller.cameraPosition == .back {
                        smallButton(nil, system: controller.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                                    label: controller.torchOn ? "Flashlight, on" : "Flashlight, off") {
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
                    Text("Double tap anywhere to take it now")
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
        .accessibilityAction(.magicTap) { controller.shootNow() }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { cameraFocused = true }
        }
    }

    // MARK: Taken

    private var taken: some View {
        VStack(spacing: 18) {
            topBar(title: "Picture Taken", back: { controller.backToChoices() }, backLabel: "Back to choices")
            if let photo = controller.lastPhoto {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(12)
                    .frame(maxHeight: 360)
                    .accessibilityLabel("The picture you just took")
            }
            Text(controller.statusText)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            AimBigButton(emoji: "📸", title: "Take Another", color: .green,
                         hint: "Aim at \(controller.subject?.spokenName ?? "the same thing") again") {
                controller.takeAnother()
            }
            AimBigButton(emoji: "↩️", title: "Back", color: .gray, hint: "Back to the three choices") {
                controller.backToChoices()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: Pieces

    private func topBar(title: String, back: @escaping () -> Void, backLabel: String) -> some View {
        HStack {
            smallButton("Back", system: "chevron.left", label: backLabel, action: back)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(emoji).font(.system(size: 34))
                OutlinedText(text: title, fontSize: 24)
            }
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
        .accessibilityLabel(title)
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
                         title: listener.isRunning ? "Listening… tap to stop" : "Speak",
                         color: listener.isRunning ? .red : .purple,
                         hint: listener.isRunning ? "Stops listening" : "Tap, then say what you're looking for",
                         action: action)
            if !listener.transcript.isEmpty {
                // Shown for sighted helpers; the spoken reply covers VoiceOver.
                Text("Heard: \(listener.transcript)")
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
        /// What goes to Photos: the cropped JPEG, or the winner as shot.
        var photo: Data
        /// The winner as shot (only differs from `photo` when cropped).
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
        var photo = original
        var shown: UIImage?
        if let box = scored[winner].box,
           let rect = AimBurst.crop(box: box, imageSize: size, framing: framing),
           let full = uprightImage(original, maxSide: max(size.width, size.height)),
           let cut = full.cropping(to: rect) {
            let image = UIImage(cgImage: cut)
            if let jpeg = image.jpegData(compressionQuality: 0.92) {
                crop = rect
                photo = jpeg
                shown = image
            }
        }
        if shown == nil { shown = UIImage(data: original) }
        let info = ShotInfo(
            subject: subjectName, winner: winner, imageWidth: size.width, imageHeight: size.height,
            crop: crop.map { [$0.minX, $0.minY, $0.width, $0.height] },
            frames: scored.enumerated().map { i, f in
                FrameInfo(index: i, box: f.box.map { [$0.minX, $0.minY, $0.width, $0.height] },
                          sharpness: f.sharpness, score: AimBurst.score(f, framing: framing))
            })
        return Result(image: shown, keep: Kept(photo: photo, original: original, cropped: crop != nil, info: info))
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
        if kept.cropped {
            try? kept.photo.write(to: dir.appendingPathComponent("\(stamp)-saved-cropped.jpg"))
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let json = try? enc.encode(kept.info) {
            try? json.write(to: dir.appendingPathComponent("\(stamp)-info.json"))
        }
    }
}
#endif
