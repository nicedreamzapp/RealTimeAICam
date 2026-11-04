#if DEBUG && targetEnvironment(simulator)
import AVFoundation
import ObjectiveC

/// Simulator runs are silent (Matt heard the sims, 2026-11-04): every utterance is
/// spoken at volume 0, so speech still starts and finishes (the callbacks and logs
/// tests rely on) but nothing comes out of the Mac's speakers, and the Mac's own
/// volume is never touched. Debug Simulator builds only; RTCAM_SIM_AUDIBLE=1 opts out.
enum SimulatorSilence {
    private static var installed = false

    static func install() {
        guard !installed, ProcessInfo.processInfo.environment["RTCAM_SIM_AUDIBLE"] != "1" else { return }
        installed = true
        let cls: AnyClass = AVSpeechSynthesizer.self
        guard let original = class_getInstanceMethod(cls, #selector(AVSpeechSynthesizer.speak(_:))),
              let silent = class_getInstanceMethod(cls, #selector(AVSpeechSynthesizer.rtcam_silentSpeak(_:)))
        else { return }
        method_exchangeImplementations(original, silent)
    }
}

extension AVSpeechSynthesizer {
    @objc func rtcam_silentSpeak(_ utterance: AVSpeechUtterance) {
        utterance.volume = 0
        rtcam_silentSpeak(utterance) // the original speak(_:) after the exchange
    }
}
#endif
