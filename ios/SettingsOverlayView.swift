import SwiftUI

struct SettingsOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    /// Picking Spanish in Your language redraws the whole panel in Spanish.
    @ObservedObject private var appLang = AppLangObserver.shared
    @Binding var isPresented: Bool
    let mode: AppMode

    @StateObject private var buttonDebouncer = ButtonPressDebouncer()

    /// Shared with LiveOCRView through the same defaults key.
    @AppStorage("countdownBeforeCapture") private var countdownBeforeCapture = true

    /// Off hands every spoken line to VoiceOver instead of saying it in the
    /// app's own voice. Asked for on AppleVis by Cash (2026-09-12).
    @AppStorage("speakAnswersAloud") private var speakAnswersAloud = true

    @State private var copyHistory: [String] = UserDefaults.standard.stringArray(forKey: "ocrCopyHistory") ?? []
    @State private var copiedIndex: Int?

    var body: some View {
        ZStack {
            Color.black.opacity(mode == .home ? 0.75 : 0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    if buttonDebouncer.canPress("SettingsOverlayView-1") {
                        withAnimation(.spring(response: 0.3)) {
                            isPresented = false
                        }
                    }
                }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack {
                    Text(L("Settings"))
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    Button(action: {
                        if buttonDebouncer.canPress("SettingsOverlayView-2") {
                                withAnimation(.spring(response: 0.3)) {
                                isPresented = false
                            }
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(L("Close settings"))
                }
                .padding()

                Divider()
                    .opacity(0.5)

                ScrollView {
                    VStack(spacing: 20) {
                        if mode == .ocrEnglish {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: $countdownBeforeCapture) {
                                    HStack {
                                        Image(systemName: "timer")
                                            .font(.system(size: 20))
                                            .foregroundStyle(.purple)
                                        Text(L("Countdown before photo"))
                                            .font(.headline)
                                    }
                                }
                                .accessibilityLabel(L("Countdown before photo"))
                                .accessibilityHint(L("When on, the app counts three, two, one out loud and then takes the picture, so you are not touching the phone when it fires"))

                                Text(L("Counts three, two, one out loud, then takes the picture — your hand is off the phone when it fires."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.gray.opacity(0.1))
                            )

                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: $speakAnswersAloud) {
                                    HStack {
                                        Image(systemName: "speaker.wave.2")
                                            .font(.system(size: 20))
                                            .foregroundStyle(.blue)
                                        Text(L("Speak in the app's own voice"))
                                            .font(.headline)
                                    }
                                }
                                .accessibilityLabel(L("Speak in the app's own voice"))
                                .accessibilityHint(L("Turn this off and VoiceOver reads the descriptions instead, so two voices are not talking at once"))

                                Text(L("Turn this off and VoiceOver reads everything instead, in your voice and at your speed, so the app is not talking over it."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.gray.opacity(0.1))
                            )
                        }

                        if mode == .ocrEnglish || mode == .ocrSpanish {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "doc.on.clipboard")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.orange)

                                    Text(L("Copy History"))
                                        .font(.headline)

                                    Spacer()

                                    if !copyHistory.isEmpty {
                                        Button(L("Clear")) {
                                            if buttonDebouncer.canPress("SettingsOverlayView-3") {
                                                copyHistory.removeAll()
                                                UserDefaults.standard.removeObject(forKey: "ocrCopyHistory")
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .accessibilityLabel(L("Clear copy history"))
                                        .accessibilityHint(L("Deletes every saved copy from this device"))
                                    }
                                }

                                if copyHistory.isEmpty {
                                    Text(L("No copied text yet"))
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 20)
                                } else {
                                    VStack(spacing: 8) {
                                        ForEach(Array(copyHistory.enumerated()), id: \.offset) { index, text in
                                            HStack {
                                                Text(text)
                                                    .font(.system(.body, design: .monospaced))
                                                    .lineLimit(2)
                                                    .frame(maxWidth: .infinity, alignment: .leading)

                                                Button(action: {
                                                    if buttonDebouncer.canPress("SettingsOverlayView-4") {
                                                        UIPasteboard.general.string = text

                                                        let generator = UINotificationFeedbackGenerator()
                                                        generator.notificationOccurred(.success)
                                                        // Visible confirmation alongside the haptic
                                                        withAnimation(.easeIn(duration: 0.15)) { copiedIndex = index }
                                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                                            withAnimation(.easeOut(duration: 0.3)) {
                                                                if copiedIndex == index { copiedIndex = nil }
                                                            }
                                                        }
                                                    }
                                                }) {
                                                    if copiedIndex == index {
                                                        HStack(spacing: 3) {
                                                            Image(systemName: "checkmark.circle.fill")
                                                            Text(L("Copied")).font(.caption.bold())
                                                        }
                                                        .foregroundStyle(.green)
                                                    } else {
                                                        Image(systemName: "doc.on.doc")
                                                            .font(.body)
                                                            .foregroundStyle(.blue)
                                                    }
                                                }
                                                .accessibilityLabel(copiedIndex == index ? L("Copied") : L("Copy this saved text"))
                                                .accessibilityHint(L("Copies it to the clipboard"))
                                            }
                                            .padding(12)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(.ultraThinMaterial.opacity(0.2))
                                            )
                                        }
                                    }
                                }
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial.opacity(0.3))
                            )
                        }

                        if viewModel.currentZoomLevel > 1.05 || viewModel.currentZoomLevel < 0.95 {
                            HStack {
                                Image(systemName: "camera.viewfinder")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.purple)

                                Text(L("Camera Zoom"))
                                    .font(.headline)

                                Spacer()

                                Text(String(format: "%.1fx", viewModel.currentZoomLevel))
                                    .font(.system(.title3, design: .rounded))
                                    .fontWeight(.medium)
                                    .foregroundStyle(.purple)
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial.opacity(0.3))
                            )
                        }

                        // Camera-screen tips; from home they would point at
                        // controls that aren't there (2026-11-03).
                        if mode != .home {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.blue)

                                Text(L("Tips"))
                                    .font(.headline)
                            }

                            // This overlay is only ever presented from the OCR screens
                            Text(L("• 🤏 Pinch to zoom the camera"))
                                .voiceOverWords(L("• 🤏 Pinch to zoom the camera"))
                            Text(L("• 📋 Copy detected/translated text"))
                                .voiceOverWords(L("• 📋 Copy detected/translated text"))
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text(L("Reset/Stop — Clears text, translation, and stops speaking"))
                            }
                            Text(L("• 🗣️ Speak detected/translated text"))
                                .voiceOverWords(L("• 🗣️ Speak detected/translated text"))
                            Text("• " + L("🔦 Flashlight, one tap on, one tap off"))
                                .voiceOverWords(L("🔦 Flashlight, one tap on, one tap off"))
                            // No lens line here: these screens have no lens
                            // toggle at all — it lives in Object Detection, and
                            // only on phones with a second rear lens. Listing it
                            // here sent Matt on AppleVis hunting for a control
                            // that was never on this screen (2026-09-17).
                            Text(L("• ⚙️ Open settings/history"))
                                .voiceOverWords(L("• ⚙️ Open settings/history"))
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.ultraThinMaterial.opacity(0.3))
                        )
                        }

                        YourLanguageCard()
                        ModelsCardView()
                        PrivacyCardView()
                        CreditsCardView()
                    }
                    .padding()
                }
            }
            .frame(maxWidth: 380, maxHeight: 600)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial.opacity(mode == .home ? 1 : 0.8))
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(mode == .home ? 0.55 : 0)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .shadow(radius: 20)
            .scaleEffect(isPresented ? 1 : 0.9)
            .opacity(isPresented ? 1 : 0)
            // Keeps VoiceOver inside the panel while it is open
            .accessibilityAddTraits(.isModal)
        }
        .gesture(
            DragGesture().onEnded { value in
                if value.translation.height > 80, abs(value.translation.width) < 50 {
                    if buttonDebouncer.canPress("SettingsOverlayView-5") {
                        withAnimation(.spring(response: 0.3)) {
                            isPresented = false
                        }
                    }
                }
            }
        )
        // VoiceOver's escape (two-finger Z) closes Settings, like the close button.
        .accessibilityAction(.escape) {
            withAnimation(.spring(response: 0.3)) { isPresented = false }
        }
    }

    static func addToCopyHistory(_ text: String) {
        var history = UserDefaults.standard.stringArray(forKey: "ocrCopyHistory") ?? []

        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        history = Array(history.prefix(5))

        UserDefaults.standard.set(history, forKey: "ocrCopyHistory")
    }
}

private struct PrivacyCardView: View {
    @ObservedObject private var appLang = AppLangObserver.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.green)
                Text(L("Private by Design"))
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label(L("Works 100% offline — even in Airplane Mode (the optional bigger models download once, then stay offline)"), systemImage: "airplane")
                Label(L("No tracking, no analytics, no accounts"), systemImage: "eye.slash")
                Label(L("Camera frames are processed on-device only"), systemImage: "camera.viewfinder")
                Label(L("Copy history stays on this device (you can clear it anytime)"), systemImage: "doc.on.clipboard")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}

/// Who the app is built on. The LFM Open License asks that everyone who gets
/// the model also gets the license, so its full text opens right here
/// (it ships inside the VisionModel folder).
private struct CreditsCardView: View {
    @State private var showLicense = false
    @ObservedObject private var appLang = AppLangObserver.shared

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "VisionModel", withExtension: nil)?
            .appendingPathComponent("LFM-Open-License-v1.0.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.pink)
                Text(L("Credits"))
                    .font(.headline)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("What's this? runs LFM3-Omni-2B by Liquid AI, on this phone, under the LFM Open License v1.0. Nice Dreamz converted it to GGUF in three sizes (Sharp Q8_0, Clear Q3_K_M, Balanced IQ2_XS); the weights are otherwise unchanged."))
                Text(L("Quick: Vision Narrator 0.8B by Nice Dreamz, fine-tuned from Qwen3.5-0.8B by Alibaba Cloud (Apache-2.0)"))
                Button(showLicense ? L("Hide the LFM Open License") : L("Read the LFM Open License v1.0")) {
                    showLicense.toggle()
                }
                if showLicense {
                    Text(licenseText)
                        .font(.caption2)
                        .textSelection(.enabled)
                }
                Text(L("On-device engine: llama.cpp by ggml-org (MIT)"))
                Text(L("Object Detection: YOLOv8 by Ultralytics (AGPL-3.0), trained on Open Images V7 by Google (CC BY 4.0)"))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}
