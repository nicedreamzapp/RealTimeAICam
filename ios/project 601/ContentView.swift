import AVFoundation
import CoreVideo
import SwiftUI

@MainActor
struct ContentView: View {
    @SceneStorage("appMode") private var storedMode: AppMode = .home
    @State private var mode: AppMode = .home
    @StateObject private var viewModel = CameraViewModel()
    @State private var orientation = UIDevice.current.orientation
    @StateObject private var buttonDebouncer = ButtonPressDebouncer()
    // Correct singleton pattern: use @ObservedObject for ResourceManager.shared in SwiftUI views.
    @ObservedObject private var resourceManager = ResourceManager.shared
    @ObservedObject private var shortcutRouter = ShortcutRouter.shared
    /// Redraws the screens when the app's language changes (Your language picked in Settings).
    @ObservedObject private var appLang = AppLangObserver.shared

    private var normalizedOrientation: UIDeviceOrientation {
        switch orientation {
        case .portraitUpsideDown: .portrait
        case .landscapeRight: .landscapeLeft
        default: orientation
        }
    }

    @State private var speechSynthesizer = AVSpeechSynthesizer()
    @State private var animationState = AnimationState()
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastModeSwitch = Date.distantPast
    /// Live Cam, full screen over home (2026-11-04).
    @State private var showLiveCam = false
    /// A picture shared from another app's share sheet, shown over everything.
    @ObservedObject private var sharedInbox = SharedImageInbox.shared

    private var isPortrait: Bool {
        normalizedOrientation == .portrait || !normalizedOrientation.isValidInterfaceOrientation
    }

    private var rotationAngle: Angle {
        switch normalizedOrientation {
        case .landscapeLeft: .degrees(90)
        default: .degrees(0)
        }
    }

    struct AnimationState {
        var splash = false
        var heading = false
        var button1 = false
        var button2 = false
        var button3 = false
        var button4 = false
        var button5 = false
        var picker = false
        var hasAnimatedOnce = false

        mutating func reset() {
            splash = false
            heading = false
            button1 = false
            button2 = false
            button3 = false
            button4 = false
            button5 = false
            picker = false
        }

        mutating func showAll() {
            heading = true
            button1 = true
            button2 = true
            button3 = true
            button4 = true
            button5 = true
            picker = true
        }
    }

    var body: some View {
        ZStack {
            VStack {
                Spacer()
            }
            .padding([.top, .leading], 12)

            contentForMode
                // VoiceOver stays on the shared picture while it is up.
                .accessibilityHidden(sharedInbox.isBusy)

            if mode == .home {
                VStack {
                    Spacer()
                    HStack {
                        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                        {
                            Text(verbatim: "v\(version) (\(build))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.leading, 14)
                                .padding(.bottom, 10)
                        }
                        Spacer()
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(sharedInbox.isBusy)
            }

            // The Shared picture screen, drawn at the root rather than presented: a sheet or
            // cover still on its way out can't block it, so there is nothing to wait for.
            if let shared = sharedInbox.current {
                SharedImageView(image: shared.image, onClose: closeSharedImage)
                    .id(shared.id)
                    .transition(.opacity)
                    .zIndex(10)
                    // One container marked modal, so VoiceOver stays inside it.
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
            }
        }
        .onAppear {
            #if DEBUG
            if LiveCamTest.openAtLaunch { showLiveCam = true }
            #endif
            if storedMode == .home {
                mode = storedMode
            } else {
                mode = .home
            }
        }
        .onReceive(shortcutRouter.$pendingMode) { requested in
            guard requested != nil else { return }
            // Next turn of the run loop, so on a cold launch onAppear has
            // already settled on home before the shortcut moves us.
            DispatchQueue.main.async { openFromShortcut() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            orientation = UIDevice.current.orientation
        }
        .onChange(of: scenePhase) { newValue in
            handleScenePhaseChange(newValue)
            storedMode = mode
        }
        .fullScreenCover(isPresented: $showLiveCam) {
            LiveCamView(onBack: closeLiveCam)
        }
        .onReceive(sharedInbox.$current) { shared in
            guard shared != nil else { return }
            leaveForSharedImage()
        }
        .onReceive(sharedInbox.$failed) { failed in
            guard failed else { return }
            sharedInbox.failed = false
            SpeechManager.shared.speak(L("That picture couldn't be opened."))
        }
        .alert(item: $viewModel.cameraPermissionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text(L("Open Settings"))) { alert.openSettings() },
                secondaryButton: .cancel(Text(L("Cancel")))
            )
        }
    }

    @ViewBuilder
    private var contentForMode: some View {
        switch mode {
        case .home:
            homeView

        case .ocrEnglish:
            ocrView(mode: .english)

        case .ocrSpanish:
            ocrView(mode: .spanishToEnglish)

        case .mail:
            ocrView(mode: .mail)

        case .helpMeAim:
            HelpMeAimView(
                voiceIdentifier: viewModel.selectedVoiceIdentifier,
                onBack: switchToHome
            )

        case .objectDetection:
            ObjectDetectionView(
                viewModel: viewModel,
                mode: $mode,
                orientation: normalizedOrientation,
                isPortrait: isPortrait,
                rotationAngle: rotationAngle,
                onBack: switchToHome,
                buttonDebouncer: buttonDebouncer
            )
            .ignoresSafeArea()
            .onAppear {
                // Fully reset and reconfigure the camera session for object detection
                viewModel.forceReconfigureSession()
            }
            .onDisappear {
                cleanupCurrentMode()
            }
        }
    }

    private var homeView: some View {
        HomeView(
            viewModel: viewModel,
            animationState: $animationState,
            mode: $mode,
            buttonDebouncer: buttonDebouncer,
            onEnglishOCR: {
                switchToMode(ReaderLanguage.opensTranslating ? .ocrSpanish : .ocrEnglish)
            },
            onObjectDetection: {
                switchToMode(.objectDetection)
            },
            onReadMail: {
                switchToMode(.mail)
            },
            onHelpMeAim: {
                switchToMode(.helpMeAim)
            },
            onLiveCam: openLiveCam,
            onVoiceChange: playWelcomeMessage,
            speechSynthesizer: speechSynthesizer
        )
    }

    private func ocrView(mode ocrMode: OCRMode) -> some View {
        LiveOCRView(
            mode: $mode,
            ocrMode: ocrMode,
            selectedVoiceIdentifier: viewModel.selectedVoiceIdentifier
        )
        .ignoresSafeArea()
    }

    /// Live Cam from the home button: nothing else may hold the camera or talk while it is open.
    private func openLiveCam() {
        viewModel.stopSession()
        SpeechManager.shared.resetSpeechState()
        showLiveCam = true
    }

    private func closeLiveCam() {
        showLiveCam = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            UIAccessibility.post(notification: .screenChanged,
                                 argument: SpeechManager.voiceOverLine(L("Home screen"), lang: AppLang.code))
        }
    }

    /// A shared picture is up: leave whatever screen was up, its camera off. Home's own
    /// guide sheet and Models chooser close themselves (HomeView, ModelsCardView).
    private func leaveForSharedImage() {
        // Live Cam ends its call when its cover goes away.
        showLiveCam = false
        if mode != .home {
            performReset()
            resourceManager.switchToMode(.home)
            mode = .home
        }
        viewModel.stopSession()
        SpeechManager.shared.resetSpeechState()
    }

    /// Home says where you landed (HomeView): Settings, the guide, or the home screen.
    private func closeSharedImage() {
        sharedInbox.close()
    }

    private func switchToHome() {
        let now = Date()
        guard now.timeIntervalSince(lastModeSwitch) > 1.0 else { return }
        lastModeSwitch = now

        SpeechManager.shared.resetSpeechState()
        performReset()
        switchToMode(.home)

        viewModel.reinitialize()
    }

    private func cleanupCurrentMode() {
        SpeechManager.shared.resetSpeechState()
        viewModel.turnOffTorch()

        if mode == .objectDetection {
            viewModel.stopSession()
            viewModel.clearDetections()
        }
    }

    private func performReset() {
        // print("performReset() called - performing basic reset")

        autoreleasepool {
            viewModel.stopSession()
            SpeechManager.shared.resetSpeechState()
            viewModel.stopSpeech()
    
            viewModel.clearDetections()

            if let yoloProc = viewModel.yoloProcessor {
                yoloProc.reset()
            }

            // User settings (confidence, filter, frame rate) survive resets;
            // reinitialize() below handles the hardware-tied state.

            LiDARManager.shared.stop()
            LiDARManager.shared.cleanupOldHistories(currentDetectionIds: Set())

        }

        viewModel.reinitialize()
        // print("Basic reset completed")
    }

    private func playWelcomeMessage() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let selectedVoice = AVSpeechSynthesisVoice(identifier: viewModel.selectedVoiceIdentifier)
            let line = selectedVoice.map { L("Welcome to RealTime AI Cam. %@ voice chosen.", $0.name) }
                ?? L("Welcome to RealTime AI Cam.")
            // The picker lists the app language's voices, so the chosen one says it in that language.
            let lang = AppLang.code
            let prepared = YourLanguageVoice.prepare(SpeakableText.spoken(line, lang: lang), lang: lang,
                                                     selected: viewModel.selectedVoiceIdentifier)
            let utterance = AVSpeechUtterance(string: prepared.text)
            utterance.voice = prepared.voice
            utterance.rate = 0.5
            utterance.volume = 0.9
            speechSynthesizer.speak(utterance)
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        if mode == .helpMeAim {
            // Help Me Aim pauses and resumes its own camera and steering
            // (AppleVis: guidance in other apps died after leaving and
            // coming back), so stay on that screen instead of going home.
            if newPhase != .active { viewModel.turnOffTorch() }
            return
        }
        if newPhase == .background {
            viewModel.turnOffTorch()
            performReset()
            SpeechManager.shared.resetSpeechState()
            mode = .home
        } else if newPhase == .inactive {
            viewModel.turnOffTorch()
            viewModel.stopSession()
        } else if newPhase == .active {
            // Coming back from Control Center / notification shade is not a fresh
            // launch — just restart the paused session; don't wipe the user's state.
            if mode == .objectDetection {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    viewModel.startSession()
                }
            }
        }
    }

    /// The whole screen is replaced on a mode switch. Tell VoiceOver so it moves
    /// focus and says where it landed instead of going silent.
    private func announceScreenChange(to newMode: AppMode) {
        let name: String = switch newMode {
        case .home: L("Home screen")
        case .objectDetection: L("Object detection camera")
        case .ocrEnglish: L("English text reader")
        case .ocrSpanish: L("Translator")
        case .mail: L("Mail reader")
        case .helpMeAim: L("Help Me Aim")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            UIAccessibility.post(notification: .screenChanged,
                                 argument: SpeechManager.voiceOverLine(name, lang: AppLang.code))
        }
    }

    /// Siri, Shortcuts or the Action Button asked for a screen. From another
    /// camera screen, tear that one down first, the same as the back button does.
    private func openFromShortcut() {
        guard let requested = shortcutRouter.pendingMode else { return }
        shortcutRouter.pendingMode = nil
        guard requested != mode else {
            announceScreenChange(to: requested)
            return
        }
        if mode != .home {
            performReset()
        }
        switchToMode(requested)
    }

    private func switchToMode(_ newMode: AppMode) {
        // Ensure newMode is the AppMode enum expected by ResourceManager.switchToMode()
        resourceManager.switchToMode(newMode)
        mode = newMode
        announceScreenChange(to: newMode)

        // Every camera mode needs this: OCR uses its own capture pipeline that
        // never checks, and a denied user otherwise gets a silent black screen.
        if newMode != .home {
            viewModel.checkAndHandleCameraPermission()
        }
    }
}

#Preview {
    ContentView()
}
