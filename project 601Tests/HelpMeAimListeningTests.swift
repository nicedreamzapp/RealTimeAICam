@testable import RealTime_Ai_Cam
import Foundation
import Testing

// Something Else asks, beeps, listens by itself (Matt: "you don't know when
// to speak, if you need to press the button, or hold it").
struct HelpMeAimListeningTests {
    @Test func phrases() {
        #expect(AimPhrases.askWhat == "After the beep, say what you're looking for.")
        #expect(AimPhrases.heardNothing == "I didn't hear anything. Tap Speak to try again, or type it.")
        #expect(AimPhrases.didntCatch == "I didn't catch that. Tap Speak to try again.")
        #expect(AimPhrases.speakLabel == "Speak, tap once, then say what you're looking for after the beep")
        let key = AimSubject.object(AimVocabulary.Match(spokenName: "key", classNames: ["key"], classIDs: [1]))
        #expect(AimPhrases.intro(for: key).hasPrefix("Looking for a key."))
    }

    @Test func stopsAfterSilenceOnceSomethingWasSaid() {
        #expect(!AimListening.shouldStop(heardSomething: true, quiet: 1.2, total: 3))
        #expect(AimListening.shouldStop(heardSomething: true, quiet: 1.3, total: 3))
    }

    @Test func givesUpAfterSixSecondsOfNothing() {
        #expect(!AimListening.shouldStop(heardSomething: false, quiet: 5.9, total: 5.9))
        #expect(AimListening.shouldStop(heardSomething: false, quiet: 6.0, total: 6.0))
        // Still talking at 7 s is fine; 9 s is the hard stop.
        #expect(!AimListening.shouldStop(heardSomething: true, quiet: 0.2, total: 7))
        #expect(AimListening.shouldStop(heardSomething: true, quiet: 0.2, total: 9))
    }

    @Test func resultsAndReplies() {
        #expect(AimListening.result(transcript: "  keys ", failed: false) == .heard("keys"))
        #expect(AimListening.result(transcript: "keys", failed: true) == .heard("keys"))
        #expect(AimListening.result(transcript: "", failed: false) == .silence)
        #expect(AimListening.result(transcript: " ", failed: true) == .notUnderstood)
        #expect(AimListening.reply(for: .silence) == AimPhrases.heardNothing)
        #expect(AimListening.reply(for: .notUnderstood) == AimPhrases.didntCatch)
        #expect(AimListening.reply(for: .heard("keys")) == nil)
        #expect(AimPhrases.cantLookFor("") == AimPhrases.didntCatch)
    }

    @Test func tonesAreValidWavAndDiffer() {
        let start = AimTones.wav(AimTones.start)
        let end = AimTones.wav(AimTones.end)
        #expect(String(decoding: start.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: start[8 ..< 12], as: UTF8.self) == "WAVE")
        let samples = Int(Double(AimTones.sampleRate) * AimTones.noteSeconds) * AimTones.start.count
        #expect(start.count == 44 + samples * 2)
        #expect(start != end)
        #expect(AimTones.start.first! < AimTones.start.last!) // rising
        #expect(AimTones.end.first! > AimTones.end.last!) // falling
        #expect(abs(AimTones.duration - 0.18) < 1e-9)
        // Starts and ends silent (no click).
        let firstSample = start[44 ..< 46].withUnsafeBytes { $0.load(as: Int16.self) }
        #expect(firstSample == 0)
    }
}
