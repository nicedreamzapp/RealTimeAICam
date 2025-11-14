import ARKit
import AVFoundation
import Combine // ✅ Needed for ObservableObject / @Published
import SwiftUI

// Small speaker helper so we can track speaking state and stop on dismiss
final class InstructionsSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking = false
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func play(script: String, voiceId: String? = nil, rate: Float = 0.48) {
        // Stop anything already playing to avoid overlap
        stop()

        let utterance = AVSpeechUtterance(string: script)
        utterance.rate = rate
        utterance.volume = 1.0

        // Try to use the provided voice ID first
        if let voiceId, !voiceId.isEmpty {
            if let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
                utterance.voice = voice
            } else {
                // Try to find a matching voice by partial ID match
                let allVoices = AVSpeechSynthesisVoice.speechVoices()
                if let matchingVoice = allVoices.first(where: { $0.identifier == voiceId }) {
                    utterance.voice = matchingVoice
                } else {
                    // Fallback to default English voice
                    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                }
            }
        } else {
            // No voice ID provided, use default
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        // Activate audio (mix with others so it doesn't kill other audio)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        synth.speak(utterance)
    }

    func stop() {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isSpeaking = false
    }

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_: AVSpeechSynthesizer, didStart _: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = true }
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        DispatchQueue.main.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.isSpeaking = false
        }
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        DispatchQueue.main.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.isSpeaking = false
        }
    }
}

struct AppInstructionsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speaker = InstructionsSpeaker()
    let selectedVoiceIdentifier: String // Make it non-optional with default

    // Only used to slightly tailor the audio line
    private var supportsLiDAR: Bool {
        if #available(iOS 14.0, *) {
            return ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        }
        return false
    }

    // In AppInstructionsView
    init(selectedVoiceIdentifier: String? = nil) {
        // Try passed voice, then UserDefaults, then system default
        self.selectedVoiceIdentifier = selectedVoiceIdentifier ??
            UserDefaults.standard.string(forKey: "selectedVoice") ??
            AVSpeechSynthesisVoice(language: "en-US")?.identifier ?? ""
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Title
                    Text("👋 Welcome to RealTime AI Camera!")
                        .font(.largeTitle.bold())

                    // Play / Stop toggle
                    DebouncedButton {
                        if speaker.isSpeaking {
                            speaker.stop()
                        } else {
                            speaker.play(script: audioScript(liDARAvailable: supportsLiDAR), voiceId: selectedVoiceIdentifier.isEmpty ? nil : selectedVoiceIdentifier)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: speaker.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                            Text(speaker.isSpeaking ? "⏹ Stop Audio" : "🎧 Play Full Audio Tutorial")
                                .fontWeight(.semibold)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background((speaker.isSpeaking ? Color.red : Color.blue).opacity(0.18))
                        .cornerRadius(12)
                    }
                    .accessibilityLabel(speaker.isSpeaking ? "Stop audio tutorial" : "Play full audio tutorial")
                    .accessibilityHint(speaker.isSpeaking ? "Stops the spoken instructions" : "Speaks a detailed guide for screen-reader users")

                    // Tagline
                    Text("Snap, Detect, Translate — all on-device.")
                        .font(.title3)

                    // Modes (exact button names)
                    Group {
                        Text("✨ **Modes**")
                            .font(.headline)

                        // 🐕 Object Detection + 📏 LiDAR sub-feature
                        VStack(alignment: .leading, spacing: 6) {
                            Text("🐕 **Object Detection**")
                                .font(.title2).fontWeight(.semibold)
                            Text("Live identification of objects (up to 601 classes) — fast, private, and works offline.")
                            Text("📏 **LiDAR Distance Assist** — In Object Detection on supported devices, tap the white ruler (turns green when active) to add distance after detections, e.g., **“Dog — 3 ft.”**")
                        }
                        .padding(.top, 4)

                        // 🔠 English OCR
                        VStack(alignment: .leading, spacing: 6) {
                            Text("🔠 **English OCR**")
                                .font(.title2).fontWeight(.semibold)
                            Text("Scan printed English text and hear it read aloud or copy it to history.")
                        }
                        .padding(.top, 8)

                        // 🇲🇽→🇺🇸 Spanish → English
                        VStack(alignment: .leading, spacing: 6) {
                            Text("🇲🇽→🇺🇸 **Spanish to English Translate**")
                                .font(.title2).fontWeight(.semibold)
                            Text("Point at printed Spanish to see instant English translation, spoken aloud and ready to copy.")
                        }
                        .padding(.top, 8)
                    }

                    // Controls
                    Group {
                        Text("🎛️ **Controls**")
                            .font(.headline)
                            .padding(.top, 6)
                        Text("🔄 Switch Camera — Front / Rear")
                        Text("🌐 Lens Toggle — Wide ↔ Ultra-wide")
                        Text("🔦 Torch — 25% / 50% / 75% / 100%")
                        Text("🤏 Pinch to Zoom")
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Reset/Stop — Clears text, translation, and stops speaking")
                        }
                        Text("🗣️ Speak Detected / Translated Text")
                        Text("📋 Copy to History")
                        Text("⚙️ Settings")
                    }

                    // Privacy
                    Group {
                        Text("🔒 **Privacy First**")
                            .font(.headline)
                            .padding(.top, 6)
                        Text("Works 100% offline — no internet required.")
                        Text("No data collection. No tracking. No location access.")
                        Text("Runs perfectly in Airplane Mode.")
                        Text("Built for iPhone — all processing stays on your device.")
                    }
                    .foregroundColor(.secondary)
                }
                .padding(24)
            }
            .navigationTitle("Instructions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    DebouncedButton {
                        speaker.stop()
                        dismiss()
                    } label: {
                        Text("Done")
                    }
                }
            }
        }
        // Also stop if user swipes down to dismiss
        .onDisappear { speaker.stop() }
    }

    // MARK: - Audio script (richer than on-screen text; avoids overlap issues)

    private func audioScript(liDARAvailable: Bool) -> String {
        var lines: [String] = []
        lines.append("Welcome to the RealTime A I Camera.")
        lines.append("There are three main modes. Object Detection. English O C R. And Spanish to English Translate.")
        if liDARAvailable {
            lines.append("In Object Detection, you can turn on LiDAR Distance Assist by tapping the white ruler. It turns green when active and adds an approximate distance after the item, for example, Dog, three feet.")
        } else {
            lines.append("LiDAR Distance Assist is not available on this device.")
        }
        lines.append("English O C R reads printed English aloud, and you can copy the text to history.")
        lines.append("Spanish to English Translate lets you point at printed Spanish and hear a natural English translation while also displaying it on screen.")
        lines.append("You can switch cameras, toggle wide or ultra wide lenses, change torch brightness, and pinch to zoom. You can show or hide the on screen text, speak the text again, and copy it.")
        lines.append("This app is built for iPhone and designed for privacy. Everything runs entirely offline. There is no data collection, no tracking, and no location access. It works perfectly in Airplane Mode.")
        return lines.joined(separator: " ")
    }
}
