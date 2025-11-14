import AVFoundation
import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var animationState: ContentView.AnimationState
    @Binding var mode: AppMode
    @State private var showInstructions = false

    @StateObject var buttonDebouncer: ButtonPressDebouncer

    let onEnglishOCR: () -> Void
    let onSpanishOCR: () -> Void
    let onObjectDetection: () -> Void
    let onVoiceChange: () -> Void
    let speechSynthesizer: AVSpeechSynthesizer

    var body: some View {
        // Use iPhone 14 Pro Max (390pt) as baseline
        let screenWidth = UIScreen.main.bounds.width
        let scale = min(screenWidth / 390, 1.0)

        return ZStack {
            splashBackground

            VStack {
                Spacer(minLength: 80)
                VStack(spacing: 12) {
                    HeadingView(animateIn: animationState.heading)
                    Spacer()
                    GeometryReader { _ in
                        VStack(spacing: 18) {
                            englishOCRButton(scale: scale, screenWidth: screenWidth)
                            spanishOCRButton(scale: scale, screenWidth: screenWidth)
                            objectDetectionButton(scale: scale, screenWidth: screenWidth)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        // GeometryReader used for vertical spacing only
                    }
                    .frame(height: 220)
                    Spacer()
                    voicePicker
                    Spacer(minLength: 25)
                }
                .padding(.horizontal)
                Spacer(minLength: 50)
            }
        }
        .overlay(alignment: .topTrailing) {
            infoButton
                .padding(.top, 8)
                .padding(.trailing, 16)
        }
        .sheet(isPresented: $showInstructions) {
            AppInstructionsView(selectedVoiceIdentifier: viewModel.selectedVoiceIdentifier)
                .onAppear {
                    if buttonDebouncer.canPress() {
                        viewModel.pauseCameraAndProcessing()
                    }
                }
                .onDisappear {
                    if buttonDebouncer.canPress() {
                        if mode == .objectDetection {
                            viewModel.resumeCameraAndProcessing()
                        }
                    }
                }
        }
        .onAppear {
            if !animationState.hasAnimatedOnce {
                animateInSequence()
                animationState.hasAnimatedOnce = true
            } else {
                animationState.showAll()
            }

            if !UserDefaults.standard.bool(forKey: "hasShownInstructions") {
                showInstructions = true
                UserDefaults.standard.set(true, forKey: "hasShownInstructions")
            }
        }
    }

    // MARK: - View Components

    private var splashBackground: some View {
        GeometryReader { _ in
            Image("SplashScreen")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea(.all, edges: .all)
        }
    }

    private func englishOCRButton(scale: CGFloat, screenWidth: CGFloat) -> some View {
        Button(action: {
            guard buttonDebouncer.canPress() else { return }
            onEnglishOCR()
        }) {
            HStack(spacing: 4 * scale) {
                Text("📖").font(.system(size: 34 * scale))
                OutlinedText(text: "Eng Text2Speech", fontSize: 20 * scale)
                ShadedEmoji(emoji: "🗣️", size: 29 * scale)
            }
            .padding(.vertical, 16 * scale)
        }
        // Adaptive width with maxWidth capped at 340 * scale or screen width minus 36
        .frame(maxWidth: min(340 * scale, screenWidth - 36), alignment: .center)
        .padding(.horizontal, 8 * scale)
        .background(
            ZStack {
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.white.opacity(0.23), Color.blue.opacity(0.50)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Capsule()
                    .fill(Color.white.opacity(0.13))
                    .frame(height: 24 * scale)
                    .offset(y: -18 * scale)
                Capsule().stroke(Color.white.opacity(0.80), lineWidth: 4.8 * scale)
                Capsule().stroke(Color.blue, lineWidth: 2.4 * scale)
                Capsule()
                    .fill(Color.black.opacity(0.12))
                    .blur(radius: 7 * scale)
                    .offset(y: 16 * scale)
            }
        )
        .shadow(color: Color.black.opacity(0.38), radius: 15 * scale, y: 5 * scale)
        .clipShape(Capsule())
        .opacity(animationState.button1 ? 1 : 0)
        .shadow(color: Color.blue.opacity(0.50), radius: 12 * scale)
        .scaleEffect(animationState.button1 ? 1 : 0.7)
        .animation(.easeOut(duration: 0.3), value: animationState.button1)
        .accessibilityLabel("English Text to Speech")
        .accessibilityHint("Point camera at English text to read it aloud")
        .accessibilityAddTraits(.isButton)
    }

    private func spanishOCRButton(scale: CGFloat, screenWidth: CGFloat) -> some View {
        Button(action: {
            guard buttonDebouncer.canPress() else { return }
            onSpanishOCR()
        }) {
            HStack(spacing: 2 * scale) {
                Text("🇲🇽").font(.system(size: 31 * scale))
                OutlinedText(text: "Span", fontSize: 18 * scale)
                Text("🇺🇸").font(.system(size: 31 * scale))
                OutlinedText(text: "Eng", fontSize: 18 * scale)
                Text("🌎").font(.system(size: 31 * scale))
                OutlinedText(text: "Translate", fontSize: 18 * scale)
            }
            .padding(.vertical, 16 * scale)
        }
        // Adaptive width with maxWidth capped at 340 * scale or screen width minus 36
        .frame(maxWidth: min(340 * scale, screenWidth - 36), alignment: .center)
        .padding(.horizontal, 8 * scale)
        .background(
            ZStack {
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.white.opacity(0.23), Color.green.opacity(0.50)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Capsule()
                    .fill(Color.white.opacity(0.13))
                    .frame(height: 24 * scale)
                    .offset(y: -18 * scale)
                Capsule().stroke(Color.white.opacity(0.80), lineWidth: 4.8 * scale)
                Capsule().stroke(Color.green, lineWidth: 2.4 * scale)
                Capsule()
                    .fill(Color.black.opacity(0.12))
                    .blur(radius: 7 * scale)
                    .offset(y: 16 * scale)
            }
        )
        .shadow(color: Color.black.opacity(0.38), radius: 15 * scale, y: 5 * scale)
        .clipShape(Capsule())
        .opacity(animationState.button2 ? 1 : 0)
        .shadow(color: Color.green.opacity(0.50), radius: 12 * scale)
        .scaleEffect(animationState.button2 ? 1 : 0.7)
        .animation(.easeOut(duration: 0.3), value: animationState.button2)
        .accessibilityLabel("Spanish to English Translator")
        .accessibilityHint("Point camera at Spanish text to translate and speak in English")
        .accessibilityAddTraits(.isButton)
    }

    private func objectDetectionButton(scale: CGFloat, screenWidth: CGFloat) -> some View {
        Button(action: {
            guard buttonDebouncer.canPress() else { return }
            onObjectDetection()
        }) {
            HStack(spacing: 4 * scale) {
                Text("🐶").font(.system(size: 35 * scale))
                OutlinedText(text: "Object Detection", fontSize: 20 * scale)
            }
            .padding(.vertical, 16 * scale)
        }
        // Adaptive width with maxWidth capped at 340 * scale or screen width minus 36
        .frame(maxWidth: min(340 * scale, screenWidth - 36), alignment: .center)
        .padding(.horizontal, 8 * scale)
        .background(
            ZStack {
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.white.opacity(0.23), Color.orange.opacity(0.50)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Capsule()
                    .fill(Color.white.opacity(0.13))
                    .frame(height: 24 * scale)
                    .offset(y: -18 * scale)
                Capsule().stroke(Color.white.opacity(0.80), lineWidth: 4.8 * scale)
                Capsule().stroke(Color.orange, lineWidth: 2.4 * scale)
                Capsule()
                    .fill(Color.black.opacity(0.12))
                    .blur(radius: 7 * scale)
                    .offset(y: 16 * scale)
            }
        )
        .shadow(color: Color.black.opacity(0.38), radius: 15 * scale, y: 5 * scale)
        .clipShape(Capsule())
        .opacity(animationState.button3 ? 1 : 0)
        .shadow(color: Color.orange.opacity(0.50), radius: 12 * scale)
        .scaleEffect(animationState.button3 ? 1 : 0.7)
        .animation(.easeOut(duration: 0.3), value: animationState.button3)
        .accessibilityLabel("Object Detection")
        .accessibilityHint("Identify objects around you and hear them announced")
        .accessibilityAddTraits(.isButton)
    }

    private var voicePicker: some View {
        AnimatedVoicePicker(
            viewModel: viewModel,
            animateIn: animationState.picker,
            onVoiceChange: onVoiceChange,
            speechSynthesizer: speechSynthesizer
        )
        .onTapGesture {
            _ = buttonDebouncer.canPress()
        }
    }

    private var infoButton: some View {
        Button(action: {
            guard buttonDebouncer.canPress() else { return }
            showInstructions = true
        }) {
            HStack(spacing: 6) {
                OutlinedText(text: "INFO", fontSize: 14)
                Text("💡").font(.system(size: 14))
                OutlinedText(text: "GUIDE", fontSize: 14)
            }
            .foregroundColor(.white)
            .padding(.vertical, 6)
            .padding(.horizontal, 18)
        }
        .background(
            ZStack {
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.white.opacity(0.23), Color.black.opacity(0.50)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Capsule()
                    .fill(Color.white.opacity(0.13))
                    .frame(height: 24)
                    .offset(y: -18)
                Capsule().stroke(Color.white.opacity(0.80), lineWidth: 4.8)
                Capsule().stroke(Color.black, lineWidth: 2.4)
                Capsule()
                    .fill(Color.black.opacity(0.12))
                    .blur(radius: 7)
                    .offset(y: 16)
            }
        )
        .shadow(color: Color.black.opacity(0.38), radius: 12, y: 5)
        .clipShape(Capsule())
    }

    // MARK: - Helper Methods

    private func animateInSequence() {
        animationState.reset()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            animationState.splash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            animationState.heading = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) {
            animationState.button1 = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.20) {
            animationState.button2 = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.70) {
            animationState.button3 = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.20) {
            animationState.picker = true
        }
    }
}
