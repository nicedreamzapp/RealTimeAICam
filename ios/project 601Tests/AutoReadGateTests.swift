@testable import RealTime_Ai_Cam
import Foundation
import Testing

/// Auto read must speak new steady text once, and never chatter on OCR wobble.
struct AutoReadGateTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func waitsForTextToHoldStillOneSecond() {
        var g = AutoReadGate()
        g.observe("Exit only, no parking", at: at(0))
        #expect(g.textToSpeak(at: at(0.5)) == nil)
        #expect(g.textToSpeak(at: at(1.0)) == "Exit only, no parking")
    }

    @Test func ocrWobbleDoesNotRestartOrRepeat() {
        var g = AutoReadGate()
        g.observe("Pharmacy open until 9 PM", at: at(0))
        g.observe("Pharmacy opn until 9 PM", at: at(0.6))       // dropped letter
        g.observe("open until 9 PM Pharmacy", at: at(1.2))      // lines swapped
        let said = g.textToSpeak(at: at(1.2))
        #expect(said != nil)
        g.markSpoken(said!)
        // Keeps wobbling for a while: nothing more is said.
        g.observe("Pharmacy open until 9 PM", at: at(1.8))
        g.observe("Pharmacy open until 9", at: at(2.4))         // lost the edge
        g.observe("harmacy open until 9 PM", at: at(3.0))
        #expect(g.textToSpeak(at: at(5.0)) == nil)
    }

    @Test func newSignIsSpokenAfterItSettles() {
        var g = AutoReadGate()
        g.observe("Push to open", at: at(0))
        g.markSpoken(g.textToSpeak(at: at(1))!)
        g.observe("Restrooms downstairs on the left", at: at(2))
        #expect(g.textToSpeak(at: at(2.5)) == nil)
        #expect(g.textToSpeak(at: at(3.0)) == "Restrooms downstairs on the left")
    }

    @Test func flickeringBetweenTwoSignsSaysNothingUntilOneHolds() {
        var g = AutoReadGate()
        g.observe("Push to open", at: at(0))
        g.observe("Restrooms downstairs", at: at(0.6))
        g.observe("Push to open", at: at(1.2))
        g.observe("Restrooms downstairs", at: at(1.8))
        #expect(g.textToSpeak(at: at(2.4)) == nil)
        #expect(g.textToSpeak(at: at(2.8)) == "Restrooms downstairs")
    }

    @Test func aPieceOfWhatWasSaidIsNotNew() {
        var g = AutoReadGate()
        g.markSpoken("Open Monday to Friday 9 to 5, closed on holidays")
        g.observe("closed on holidays", at: at(0))
        #expect(g.textToSpeak(at: at(2)) == nil)
    }

    @Test func emptyAndOneLetterReadsAreIgnored() {
        var g = AutoReadGate()
        g.observe("", at: at(0))
        #expect(g.textToSpeak(at: at(5)) == nil)
        g.observe("a", at: at(5))
        #expect(g.textToSpeak(at: at(7)) == nil)
    }

    @Test func modesCycleInOrder() {
        #expect(ReadMode.tap.next == .auto)
        #expect(ReadMode.auto.next == .mute)
        #expect(ReadMode.mute.next == .tap)
        #expect(ReadMode.allCases.map(\.title) == ["Tap to read", "Auto read", "Mute"])
    }
}
