@testable import RealTime_Ai_Cam
import AVFoundation
import Testing

/// Simulator runs never make a sound: every utterance goes out at volume 0.
struct SimulatorSilenceTests {
    @Test func utterancesAreSilentInTheSimulator() {
        #if targetEnvironment(simulator)
        SimulatorSilence.install()
        let synth = AVSpeechSynthesizer()
        let u = AVSpeechUtterance(string: "silent")
        u.volume = 0.9
        synth.speak(u)
        #expect(u.volume == 0)
        synth.stopSpeaking(at: .immediate)
        #endif
    }
}
