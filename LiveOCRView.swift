import AVFoundation
import SwiftUI

enum OCRMode {
    case english
    case spanishToEnglish
}

// Enhanced Camera Preview with zoom support
struct EnhancedCameraPreview: UIViewRepresentable {
    let onFrame: (CVPixelBuffer) -> Void
    let cameraManager: ZoomCameraManager
    var onCameraReady: ((CameraPreviewView) -> Void)?
    @ObservedObject var viewModel: LiveOCRViewModel

    var onPinchBegan: (() -> Void)?
    var onPinchEnded: (() -> Void)?

    func makeUIView(context _: Context) -> EnhancedCameraPreviewView {
        let view = EnhancedCameraPreviewView()
        view.onFrame = onFrame
        view.cameraManager = cameraManager
        view.isUltraWide = viewModel.isUltraWide
        view.cameraPosition = viewModel.cameraPosition
        view.onCameraReady = { device in
            cameraManager.setup(device: device)
            onCameraReady?(view)
        }
        view.setupGestures()
        view.onPinchBegan = onPinchBegan
        view.onPinchEnded = onPinchEnded
        return view
    }

    func updateUIView(_ uiView: EnhancedCameraPreviewView, context _: Context) {
        if uiView.isUltraWide != viewModel.isUltraWide || uiView.cameraPosition != viewModel.cameraPosition {
            uiView.isUltraWide = viewModel.isUltraWide
            uiView.cameraPosition = viewModel.cameraPosition
            uiView.reconfigureCamera()
        }
    }

    static func dismantleUIView(_ uiView: EnhancedCameraPreviewView, coordinator _: ()) {
        uiView.stopSession()
    }
}

// Enhanced CameraPreviewView with gesture support
class EnhancedCameraPreviewView: CameraPreviewView {
    var cameraManager: ZoomCameraManager?
    var onPinchBegan: (() -> Void)?
    var onPinchEnded: (() -> Void)?

    func setupGestures() {
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinchGesture)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            cameraManager?.setPinchGestureStartZoom()
            onPinchBegan?()
        case .changed:
            cameraManager?.handlePinchGesture(gesture.scale)
        case .ended, .cancelled:
            onPinchEnded?()
        default:
            break
        }
    }
}

// Liquid Glass Popup for Translation Actions
struct TranslationActionsPopup: View {
    @Binding var isPresented: Bool
    let translatedText: String
    let onCopy: () -> Void
    let onContinue: () -> Void
    let onNewScan: () -> Void

    var body: some View {
        ZStack {
            // Dim background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.3)) {
                        onContinue()
                    }
                }

            // Glass popup
            VStack(spacing: 20) {
                Text("Translation Ready")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)

                VStack(spacing: 12) {
                    // Copy button
                    Button(action: {
                        onCopy()
                        withAnimation(.spring(response: 0.3)) {
                            isPresented = false
                        }
                    }) {
                        HStack {
                            Image(systemName: "doc.on.doc.fill")
                                .font(.system(size: 18))
                            Text("Copy Translation")
                                .font(.system(size: 17, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.blue.opacity(0.3))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.blue.opacity(0.5), lineWidth: 1)
                                )
                        )
                    }

                    // Continue Reading button
                    Button(action: {
                        withAnimation(.spring(response: 0.3)) {
                            onContinue()
                        }
                    }) {
                        HStack {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 18))
                            Text("Continue Reading")
                                .font(.system(size: 17, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.green.opacity(0.3))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.green.opacity(0.5), lineWidth: 1)
                                )
                        )
                    }

                    // New Scan button
                    Button(action: {
                        withAnimation(.spring(response: 0.3)) {
                            onNewScan()
                        }
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 18))
                            Text("New Scan")
                                .font(.system(size: 17, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.orange.opacity(0.3))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                                )
                        )
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            .scaleEffect(isPresented ? 1 : 0.9)
            .opacity(isPresented ? 1 : 0)
        }
    }
}

struct LiveOCRView: View {
    @Binding var mode: AppMode
    @StateObject private var viewModel = LiveOCRViewModel()
    let ocrMode: OCRMode
    let selectedVoiceIdentifier: String

    @State private var showTextOverlay = true
    @State private var isSpeaking = false
    @State private var showSettings = false
    @State private var cameraPreviewRef: CameraPreviewView?
    @State private var showTranslationPopup = false
    @State private var isTranslating = false
    @State private var isWideScreen = false

    @State private var showTorchPresets = false

    @StateObject private var buttonDebouncer = ButtonPressDebouncer() // Debouncer to avoid rapid multiple presses

    // Computed property for display text
    private var displayText: String {
        if ocrMode == .english {
            viewModel.recognizedText
        } else {
            viewModel.isTranslated ? viewModel.translatedText : viewModel.recognizedText
        }
    }

    // Header text that changes based on state
    private var headerText: String {
        if ocrMode == .english {
            "Detected"
        } else {
            viewModel.isTranslated ? "Translation" : "Spanish Text"
        }
    }

    // Computed properties for button layout
    private func buttonLayoutMetrics(screenWidth: CGFloat, geometry: GeometryProxy) -> (buttonSize: CGFloat, spacing: CGFloat, padding: CGFloat) {
        let safeHorizontal = max(geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing, 0)
        let isVerySmallScreen = screenWidth <= 375
        let buttonSize: CGFloat = isVerySmallScreen ? 40 : 44
        let horizontalPadding: CGFloat = isVerySmallScreen ? 24 : 20
        let totalHorizontalPadding = safeHorizontal + (horizontalPadding * 2)
        let availableButtonSpace = screenWidth - totalHorizontalPadding
        let buttonCount: CGFloat = 6
        let totalButtonWidth = buttonCount * buttonSize
        let remainingSpace = availableButtonSpace - totalButtonWidth
        let idealSpacing = remainingSpace / (buttonCount - 1)
        let finalSpacing = idealSpacing >= 12 ? min(20, idealSpacing) : max(6, idealSpacing)

        return (buttonSize: buttonSize, spacing: finalSpacing, padding: horizontalPadding)
    }

    var body: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let metrics = buttonLayoutMetrics(screenWidth: screenWidth, geometry: geometry)

            ZStack {
                // Full-screen camera preview
                EnhancedCameraPreview(
                    onFrame: { pixelBuffer in
                        if !viewModel.isPinching, !isTranslating {
                            viewModel.processFrame(pixelBuffer, mode: ocrMode)
                        }
                    },
                    cameraManager: viewModel.cameraManager,
                    onCameraReady: { cameraView in
                        cameraPreviewRef = cameraView
                    },
                    viewModel: viewModel,
                    onPinchBegan: { viewModel.isPinching = true },
                    onPinchEnded: { viewModel.isPinching = false }
                )
                .ignoresSafeArea()

                // Gradient overlays
                VStack {
                    LinearGradient(
                        gradient: Gradient(colors: [Color.black.opacity(0.6), Color.clear]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 120)
                    .ignoresSafeArea()

                    Spacer()

                    LinearGradient(
                        gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.7)]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 250)
                    .ignoresSafeArea()
                }

                // Top bar
                VStack {
                    HStack {
                        // Back button (left side)
                        Button(action: {
                            if buttonDebouncer.canPress() {
                                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                                impactFeedback.impactOccurred()

                                viewModel.stopSpeaking()
                                viewModel.stopSession()
                                viewModel.clearText()
                                mode = .home
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                Text("Back")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 20)
                                    .fill(.ultraThinMaterial)
                                    .opacity(0.85)
                            )
                        }
                        .fixedSize()

                        Spacer()

                        // Mode indicator (right side)
                        Text(ocrMode == .english ? "English" : "Span → Eng")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 20)
                                    .fill(.ultraThinMaterial)
                                    .opacity(0.85)
                            )
                            .fixedSize()
                    }
                    .padding(.horizontal, max(geometry.safeAreaInsets.leading, geometry.safeAreaInsets.trailing) + 20)
                    .padding(.top, geometry.safeAreaInsets.top + 15)

                    Spacer()
                }

                // Main content area
                VStack {
                    Spacer()

                    // Text overlay - clickable when translated
                    if showTextOverlay, !displayText.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Circle()
                                    .fill(viewModel.isTranslated ? Color.green : Color.blue)
                                    .frame(width: 8, height: 8)
                                Text(headerText)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                Spacer()
                                if isTranslating {
                                    AnimatedLoader(size: 22)
                                        .scaleEffect(0.8)
                                }
                            }

                            ScrollView {
                                Text(displayText)
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 100)
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.ultraThinMaterial.opacity(0.95))
                        )
                        .onTapGesture {
                            if ocrMode == .spanishToEnglish, viewModel.isTranslated {
                                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                                impactFeedback.impactOccurred()
                                showTranslationPopup = true
                            }
                        }
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Bottom action buttons - using extracted metrics
                    HStack(spacing: metrics.spacing) {
                        // Settings button
                        Button(action: {
                            if buttonDebouncer.canPress() {
                                withAnimation(.spring(response: 0.3)) {
                                    showSettings = true
                                }
                            }
                        }) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.white)
                                .symbolRenderingMode(.palette)
                                .frame(width: metrics.buttonSize, height: metrics.buttonSize)
                                .background(
                                    Circle()
                                        .fill(.ultraThinMaterial.opacity(0.15))
                                        .background(Circle().fill(Color.black.opacity(0.25)))
                                )
                                .contentShape(Circle())
                        }

                        // Torch button with overlay for presets
                        ZStack {
                            Button(action: {
                                if buttonDebouncer.canPress() {
                                    if viewModel.torchLevel > 0 {
                                        viewModel.handleToggleTorch(level: 0.0)
                                        showTorchPresets = false
                                    } else {
                                        showTorchPresets = true
                                    }
                                }
                            }) {
                                Image(systemName: viewModel.torchLevel > 0 ? "flashlight.on.fill" : "flashlight.off.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(viewModel.torchLevel > 0 ? .yellow : .white)
                                    .symbolRenderingMode(.palette)
                                    .frame(width: metrics.buttonSize, height: metrics.buttonSize)
                                    .background(
                                        Circle()
                                            .fill(.ultraThinMaterial.opacity(0.15))
                                            .background(Circle().fill(Color.black.opacity(0.25)))
                                    )
                                    .contentShape(Circle())
                            }
                            .overlay(
                                torchPresetOverlay
                            )
                        }

                        // Wide Screen Toggle button
                        Button(action: {
                            if buttonDebouncer.canPress() {
                                viewModel.handleToggleCameraZoom()
                            }
                        }) {
                            Image(systemName: "rectangle.3.offgrid")
                                .font(.system(size: 22))
                                .foregroundStyle(viewModel.isUltraWide ? .cyan : .white)
                                .symbolRenderingMode(.palette)
                                .frame(width: metrics.buttonSize, height: metrics.buttonSize)
                                .background(
                                    Circle()
                                        .fill(.ultraThinMaterial.opacity(0.15))
                                        .background(Circle().fill(Color.black.opacity(0.25)))
                                )
                                .contentShape(Circle())
                        }

                        // Translate or Copy button
                        translateOrCopyButton(buttonSize: metrics.buttonSize)

                        // Speak button
                        speakButton(buttonSize: metrics.buttonSize)

                        // Reset (Clear) button
                        Button(action: {
                            if buttonDebouncer.canPress() {
                                withAnimation(.spring(response: 0.3)) {
                                    viewModel.stopSpeaking()
                                    viewModel.clearText()
                                    viewModel.resetTranslation()
                                    isSpeaking = false
                                }
                            }
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 22))
                                .foregroundStyle(.white)
                                .symbolRenderingMode(.palette)
                                .frame(width: metrics.buttonSize, height: metrics.buttonSize)
                                .background(
                                    Circle()
                                        .fill(.ultraThinMaterial.opacity(0.15))
                                        .background(Circle().fill(Color.black.opacity(0.25)))
                                )
                                .contentShape(Circle())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, metrics.padding + max(geometry.safeAreaInsets.leading, geometry.safeAreaInsets.trailing))
                    .padding(.bottom, 32)
                }

                // Translation popup (Spanish mode only)
                if showTranslationPopup, ocrMode == .spanishToEnglish {
                    TranslationActionsPopup(
                        isPresented: $showTranslationPopup,
                        translatedText: viewModel.translatedText,
                        onCopy: {
                            viewModel.copyText(viewModel.translatedText)
                            viewModel.continueReading()
                        },
                        onContinue: {
                            showTranslationPopup = false
                            viewModel.continueReading()
                        },
                        onNewScan: {
                            showTranslationPopup = false
                            viewModel.clearText()
                            viewModel.resetTranslation()
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(100)
                }

                // Settings overlay
                if showSettings {
                    SettingsOverlayView(
                        viewModel: CameraViewModel(),
                        isPresented: $showSettings,
                        mode: ocrMode == .english ? .ocrEnglish : .ocrSpanish
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .onAppear {
            viewModel.startSession()
        }
        .onDisappear {
            viewModel.stopSession()
            viewModel.clearText()
            viewModel.resetTranslation()
            isSpeaking = false
            viewModel.handleToggleTorch(level: 0)
        }
        .preferredColorScheme(.dark)
        .onChange(of: viewModel.torchLevel) { newLevel in
            cameraPreviewRef?.setTorchLevel(newLevel)
        }
    }

    // Helper views to break up complex expressions
    @ViewBuilder
    private var torchPresetOverlay: some View {
        Group {
            if showTorchPresets {
                VStack(spacing: 8) {
                    ForEach([100, 75, 50, 25], id: \.self) { percentage in
                        Button(action: {
                            let level = Float(percentage) / 100.0
                            viewModel.handleToggleTorch(level: level)
                            showTorchPresets = false
                        }) {
                            Text("\(percentage)%")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 60, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Int(viewModel.torchLevel * 100) == percentage ? Color.yellow.opacity(0.4) : Color.white.opacity(0.2))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Int(viewModel.torchLevel * 100) == percentage ? Color.yellow : Color.white.opacity(0.3), lineWidth: 1)
                                )
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .background(.ultraThinMaterial.opacity(0.8))
                .offset(y: -90)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func translateOrCopyButton(buttonSize: CGFloat) -> some View {
        Group {
            if ocrMode == .spanishToEnglish, !viewModel.isTranslated {
                Button(action: {
                    if buttonDebouncer.canPress() {
                        isTranslating = true
                        viewModel.translateSpanishText { success in
                            isTranslating = false
                            if success {
                                let feedback = UINotificationFeedbackGenerator()
                                feedback.notificationOccurred(.success)
                            }
                        }
                    }
                }) {
                    Image(systemName: "character.book.closed.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .symbolRenderingMode(.palette)
                        .frame(width: buttonSize, height: buttonSize)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial.opacity(0.15))
                                .background(Circle().fill(Color.black.opacity(0.25)))
                        )
                        .contentShape(Circle())
                }
                .disabled(isTranslating)
                .opacity(isTranslating ? 0.6 : 1)
            } else {
                Button(action: {
                    if buttonDebouncer.canPress() {
                        if ocrMode == .spanishToEnglish, !viewModel.isTranslated {
                            isTranslating = true
                            viewModel.translateSpanishText { success in
                                isTranslating = false
                                if success {
                                    viewModel.copyText(viewModel.translatedText)
                                    let feedback = UINotificationFeedbackGenerator()
                                    feedback.notificationOccurred(.success)
                                }
                            }
                        } else {
                            let textToCopy = ocrMode == .english ? viewModel.recognizedText : viewModel.translatedText
                            viewModel.copyText(textToCopy)
                            let feedback = UINotificationFeedbackGenerator()
                            feedback.notificationOccurred(.success)
                        }
                    }
                }) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .symbolRenderingMode(.palette)
                        .frame(width: buttonSize, height: buttonSize)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial.opacity(0.15))
                                .background(Circle().fill(Color.black.opacity(0.25)))
                        )
                        .contentShape(Circle())
                }
            }
        }
    }

    @ViewBuilder
    private func speakButton(buttonSize: CGFloat) -> some View {
        Button(action: {
            if buttonDebouncer.canPress() {
                if isSpeaking {
                    viewModel.stopSpeaking()
                    isSpeaking = false
                } else {
                    if ocrMode == .spanishToEnglish, !viewModel.isTranslated {
                        isTranslating = true
                        viewModel.translateSpanishText { success in
                            isTranslating = false
                            if success {
                                viewModel.speak(text: viewModel.translatedText, voiceIdentifier: selectedVoiceIdentifier) {
                                    isSpeaking = false
                                }
                                isSpeaking = true
                            }
                        }
                    } else {
                        let textToSpeak = ocrMode == .english ? viewModel.recognizedText : viewModel.translatedText
                        viewModel.speak(text: textToSpeak, voiceIdentifier: selectedVoiceIdentifier) {
                            isSpeaking = false
                        }
                        isSpeaking = true
                    }
                }
            }
        }) {
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .symbolRenderingMode(.palette)
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    Circle()
                        .fill(isSpeaking ? Color.green.opacity(0.3) : Color.black.opacity(0.25))
                        .overlay(
                            Circle()
                                .fill(.ultraThinMaterial.opacity(0.15))
                        )
                )
                .contentShape(Circle())
        }
        .scaleEffect(isSpeaking ? 1.1 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isSpeaking)
    }
}
