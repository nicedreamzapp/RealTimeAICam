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

        let utterance = AVSpeechUtterance(string: SpeakableText.spoken(script))
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

        // Same session as every other spoken line in the app (2026-11-04): .playback is heard
        // with the ring/silent switch on silent, .spokenAudio + duckOthers lowers music under it.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
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
                        .voiceOverWords("👋 Welcome to RealTime AI Camera!")
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
                    Text("Your camera, out loud. Everything runs on your phone.")
                        .font(.title3)

                    // The five tools, in the same order as the home screen
                    // (rewritten for the 2026-11-03 home: Read and Translate
                    // merged, Settings on home, Help Me Aim, Live Cam).
                    guideSection("📖", "Read",
                        "Point at printed text and hear it read out loud. The Language pill at the top picks English or one of 17 languages, like Spanish, French, Chinese or Arabic, and translates it into English. Spanish works right away; other languages download once from Apple, then work offline (iOS 18 or later). Auto read is on to start: new text is spoken by itself, once. The small button next to Speak switches between Auto read, Mute and Tap to read. Copy keeps the text in your history.")
                    guideSection("🐶", "Object Detection",
                        "Names the things around you as you move the phone, nonstop, fast and offline." + (supportsLiDAR
                            ? " On phones with LiDAR, tap the white ruler (it turns green) to hear distances, like Dog, 3 feet."
                            : ""))
                    guideSection("📄", "What's this?",
                        "One careful look. Point at a page, a bill, a package or a room and press the button. Mail and pages get the point of them: who sent it, what it is, what's due. A room or a thing gets a description. Afterwards, hold to ask a follow-up question about the same photo.")
                    guideSection("🎯", "Help Me Aim",
                        "Takes a good photo for you. Choose Face, Picture or Page, or Something Else and say or type what you want, like keys, a mug or your dog. The app tells you which way to move, counts down and takes the picture, then saves it to Photos with a description written into it. It knows thousands of everyday things; for anything else, like a wallet, it looks closely with the describing AI and tells you where it is. Double tap anywhere to take the picture yourself.")
                    guideSection("💬", "Live Cam",
                        "Experimental. A conversation with the camera. It says hello, then listens the whole time: just talk, there is nothing to press. Ask what's in front of you, what a sign says, what color something is, or anything else, and it answers out loud a sentence at a time. Talk over it to cut in; say stop, or use the red Back button, to leave. Mode at the top picks Normal, Funny, Analyze or Coach, or just say funny mode, analyze this or coach me. Flip camera switches to the selfie side. Mute stops it listening. While you're quiet it checks in now and then and mentions new things it is sure it sees; turn Speak up off in Mode to stop that. With VoiceOver, a two-finger double tap stops it talking and the escape gesture leaves. It uses the same describing AI as What's this?, so it works offline, and it speaks in Your language. The first time, it asks for the microphone and speech recognition; your voice is turned into text on the phone and nothing is recorded.")

                    // Settings and models
                    guideSection("⚙️", "Settings",
                        "The Settings button at the top of the home screen. Models: the app picks the best describing AI for your phone by itself and downloads it once, on Wi-Fi. Mail, money and medicine always get the most accurate one your phone can run. In Settings, then Models, you can choose Most accurate or Fastest, or pick one yourself. The voice button at the bottom of the home screen changes the voice.")

                    guideSection("🌍", "Your language",
                        String(YourLanguageRules.guide.dropFirst("Your language: ".count)).capitalizedFirst)

                    // Camera controls (inside each tool)
                    Group {
                        Text("🎛️ **Camera controls**")
                            .voiceOverWords("🎛️ **Camera controls**")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, 6)
                        Text("🔄 Switch camera, front or back")
                            .voiceOverWords("🔄 Switch camera, front or back")
                        if CameraCapabilities.hasUltraWideRear {
                            Text("🌐 Lens toggle, wide or ultra-wide (Object Detection)")
                                .voiceOverWords("🌐 Lens toggle, wide or ultra-wide (Object Detection)")
                        }
                        Text("🔦 Flashlight, one tap on, one tap off")
                            .voiceOverWords("🔦 Flashlight, one tap on, one tap off")
                        Text("🤏 Pinch to zoom")
                            .voiceOverWords("🤏 Pinch to zoom")
                    }

                    // Privacy
                    Group {
                        Text("🔒 **Private by design**")
                            .voiceOverWords("🔒 **Private by design**")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, 6)
                        Text("Everything runs on your phone and works offline, even in Airplane Mode. The bigger AI models and translation languages download once, then stay on your phone.")
                        Text("No accounts, no tracking, no location access. Nothing you point the camera at is uploaded.")
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

    /// One tool: a heading VoiceOver can jump to, then what it does.
    private func guideSection(_ emoji: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(emoji) **\(title)**")
                .voiceOverWords(title)
                .font(.title2).fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
            Text(text)
        }
        .padding(.top, 8)
    }

    // MARK: - Audio script (richer than on-screen text; avoids overlap issues)

    private func audioScript(liDARAvailable: Bool) -> String {
        var lines: [String] = []
        lines.append("Welcome to the RealTime A I Camera.")
        lines.append("The home screen has two buttons at the top, Settings and Info and guide, then five tools, then the voice button. Swipe through them, or touch the screen to explore.")
        lines.append("Read. Point at printed text and hear it out loud. The Language button at the top picks English, or one of 17 languages to translate into English. Swipe up or down on it to change. The small button next to Speak switches between Auto read, which is on to start and reads new text by itself, Mute, and Tap to read.")
        lines.append("Object Detection names the things around you as you move the phone.")
        if liDARAvailable {
            lines.append("Tap the white ruler to add distances, for example, Dog, three feet.")
        }
        lines.append("What's this? takes one careful look. Mail and pages get the point of them, like who sent it and what's due. A room gets a description. Afterwards, hold to ask a follow up question.")
        lines.append("Help Me Aim takes a good photo for you. Choose Face, Picture or Page, or Something Else and say what you want. It tells you which way to move, counts down, and saves the photo with a description. For things it doesn't know by sight, like a wallet, it looks closely and tells you where it is. Double tap anywhere to take the picture yourself.")
        lines.append("Live Cam, which is experimental, is a conversation with the camera. It says hello, then listens the whole time, so just talk. Ask what's in front of you, what a sign says, or anything else, and it answers out loud. Talk over it to cut in. Say stop, or press the red Back button, to leave. The Mode button picks Normal, Funny, Analyze or Coach, or just say funny mode, analyze this, or coach me. With VoiceOver, a two finger double tap stops it talking. It works offline and nothing is recorded.")
        lines.append("In Settings, Models, the app already picked the best A I for your phone. You can choose Most accurate or Fastest there.")
        lines.append(YourLanguageRules.guide)
        lines.append("Everything runs on your phone and works offline. No accounts and no tracking.")
        return lines.joined(separator: " ")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
