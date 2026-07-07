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
        var picker = false
        var hasAnimatedOnce = false

        mutating func reset() {
            splash = false
            heading = false
            button1 = false
            button2 = false
            button3 = false
            picker = false
        }

        mutating func showAll() {
            heading = true
            button1 = true
            button2 = true
            button3 = true
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

            if mode == .home {
                VStack {
                    Spacer()
                    HStack {
                        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                        {
                            Text("v\(version) (\(build))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.leading, 14)
                                .padding(.bottom, 10)
                        }
                        Spacer()
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            if storedMode == .home {
                mode = storedMode
            } else {
                mode = .home
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            orientation = UIDevice.current.orientation
        }
        .onChange(of: scenePhase) { newValue in
            handleScenePhaseChange(newValue)
            storedMode = mode
        }
        .alert(item: $viewModel.cameraPermissionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text("Open Settings")) { alert.openSettings() },
                secondaryButton: .cancel()
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
                switchToMode(.ocrEnglish)
            },
            onSpanishOCR: {
                switchToMode(.ocrSpanish)
            },
            onObjectDetection: {
                switchToMode(.objectDetection)
            },
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
            let voiceName = selectedVoice?.name ?? "Selected"
            let utterance = AVSpeechUtterance(string: "Welcome to the real-time AI. iOS Detection app. \(voiceName) voice chosen")
            utterance.voice = selectedVoice
            utterance.rate = 0.5
            utterance.volume = 0.9
            speechSynthesizer.speak(utterance)
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        if newPhase == .background {
            performReset()
            SpeechManager.shared.resetSpeechState()
            mode = .home
        } else if newPhase == .inactive {
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

    private func switchToMode(_ newMode: AppMode) {
        // Ensure newMode is the AppMode enum expected by ResourceManager.switchToMode()
        resourceManager.switchToMode(newMode)
        mode = newMode

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
