@testable import RealTime_Ai_Cam
import CoreGraphics
import Foundation
import Testing

/// Talk to the camera: the pieces that decide what is asked, what is said
/// first, and when the person has finished talking.
struct TalkBrainTests {
    // MARK: Streaming sentences

    @Test func firstSentenceComesOutBeforeTheRest() {
        var s = TalkSentenceStream()
        #expect(s.feed("That's a car eng").isEmpty)
        #expect(s.feed("That's a car engine.").isEmpty) // not sure it ended yet
        #expect(s.feed("That's a car engine. The") == ["That's a car engine."])
        #expect(s.feed("That's a car engine. The oil cap is on the left.").isEmpty)
        #expect(s.feed("That's a car engine. The oil cap is on the left.", final: true) == ["The oil cap is on the left."])
    }

    @Test func decimalsAreNotSentenceEnds() {
        var s = TalkSentenceStream()
        #expect(s.feed("It reads 3.5 volts on the meter. Next").count == 1)
    }

    @Test func thinkingAndMarkdownAreNeverSpoken() {
        var s = TalkSentenceStream()
        let out = s.feed("<think>hmm</think>**A red cup** on the table. ", final: true)
        #expect(out == ["A red cup on the table."])
        #expect(TalkSentenceStream.cleaned("<think>still thinking") == "")
    }

    // MARK: Routing

    @Test func pagesMoneyMedicineAndLabelsUseThePageRoute() {
        #expect(TalkRouting.asksAboutPage("What does this letter say?"))
        #expect(TalkRouting.asksAboutPage("how much do I owe"))
        #expect(TalkRouting.asksAboutPage("When does this medicine expire?"))
        #expect(TalkRouting.asksAboutPage("read the label"))
        #expect(!TalkRouting.asksAboutPage("what color is the hose"))
        #expect(!TalkRouting.asksAboutPage("is anyone in the room"))
    }

    @Test func whatsThisSpokenIsTheSameQuestion() {
        #expect(TalkRouting.isWhatsThis("What's this?"))
        #expect(TalkRouting.isWhatsThis("what am I looking at"))
        #expect(!TalkRouting.isWhatsThis("how do I check the oil"))
    }

    @Test func endAndRepeat() {
        #expect(TalkRouting.intent(of: "Stop") == .end)
        #expect(TalkRouting.intent(of: "okay goodbye") == .end)
        #expect(TalkRouting.intent(of: "say that again") == .repeatLast)
        #expect(TalkRouting.intent(of: "what about that hose") == .ask)
        // "stop" inside a real question is a question.
        #expect(TalkRouting.intent(of: "where is the stop sign") == .ask)
    }

    @Test func screenReaderEchoIsIgnored() {
        #expect(TalkRouting.isEcho("Listening"))
        #expect(!TalkRouting.isEcho("listening to what"))
    }

    @Test func questionNamesADetectedThing() {
        let seen = [TalkSeen(name: "Cup", box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)),
                    TalkSeen(name: "Bat (Animal)", box: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))]
        #expect(TalkRouting.namedThing(in: "is the cup full?", among: seen)?.name == "Cup")
        #expect(TalkRouting.namedThing(in: "are those cups clean", among: seen)?.name == "Cup")
        #expect(TalkRouting.namedThing(in: "is that a bat", among: seen)?.name == "Bat (Animal)")
        #expect(TalkRouting.namedThing(in: "what's on the shelf", among: seen) == nil)
    }

    // MARK: Prompt and memory

    @Test func promptCarriesDetectorMemoryAndQuestion() {
        let seen = [TalkSeen(name: "Chair", box: CGRect(x: 0.05, y: 0.4, width: 0.2, height: 0.3)),
                    TalkSeen(name: "Person", box: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.6))]
        let history = [TalkMemory.Exchange(question: "what's this", answer: "A car engine.", at: Date())]
        let text = TalkPrompt.userText(question: "what about that hose?", seen: seen, newThings: ["Dog"],
                                       caption: nil, history: history)
        #expect(text.contains("Detector sees (it can be wrong): chair on the left, person ahead."))
        #expect(text.contains("Just appeared: dog."))
        #expect(text.contains("You said: A car engine."))
        #expect(text.hasSuffix("Question: what about that hose?"))
    }

    @Test func detectorLineIsInstant() {
        let seen = [TalkSeen(name: "Chair", box: CGRect(x: 0.05, y: 0.4, width: 0.2, height: 0.3)),
                    TalkSeen(name: "Person", box: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.6))]
        #expect(TalkPrompt.detectorLine(seen) == "I can see a chair on the left and a person ahead.")
        #expect(TalkPrompt.detectorLine([]) == nil)
    }

    @Test func memoryKeepsTheLastFew() {
        let m = TalkMemory()
        let t = Date()
        for i in 0 ..< 5 { m.note(question: "q\(i)", answer: "a\(i)", at: t) }
        #expect(m.recent(at: t).map(\.answer) == ["a2", "a3", "a4"])
        #expect(m.recent(at: t.addingTimeInterval(TalkMemory.maxAge + 1)).isEmpty)
    }

    @Test func sceneMemorySaysWhatIsNew() {
        var scene = TalkSceneMemory()
        let t = Date()
        let chair = TalkSeen(name: "Chair", box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        let dog = TalkSeen(name: "Dog", box: CGRect(x: 0.7, y: 0.5, width: 0.2, height: 0.2))
        scene.update([chair], at: t)
        scene.update([chair], at: t.addingTimeInterval(20))
        scene.update([chair, dog], at: t.addingTimeInterval(21))
        #expect(scene.newThings(at: t.addingTimeInterval(22)) == ["Dog"])
    }

    // MARK: Aim help and turn taking

    @Test func aimHelpUsesTheExistingSteering() {
        #expect(TalkAim.pageTip(cutOffEdge: "left") == "Cut off on the left, move the phone left a little.")
        let cutOff = TalkSeen(name: "Cup", box: CGRect(x: 0.85, y: 0.4, width: 0.15, height: 0.2))
        #expect(TalkAim.subjectTip(for: cutOff)?.contains("move the phone right") == true)
        let centered = TalkSeen(name: "Cup", box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        #expect(TalkAim.subjectTip(for: centered) == nil)
        #expect(TalkAim.tip(isPage: false, cutOffEdge: nil, named: nil, qualityHint: "dark")?.hasPrefix("It's dark") == true)
    }

    @Test func questionEndsAfterAboutASecondOfQuiet() {
        #expect(!TalkTiming.questionEnded(heardSomething: true, quiet: 0.8))
        #expect(TalkTiming.questionEnded(heardSomething: true, quiet: 1.25))
        #expect(!TalkTiming.questionEnded(heardSomething: false, quiet: 5))
    }

    @Test func bargeInNeedsAVoiceOverTheEcho() {
        var b = TalkBargeIn()
        // The app's own echo, steady around -45 dB: never a barge-in.
        var echoFired = false
        for _ in 0 ..< 40 { echoFired = echoFired || b.feed(level: -45) }
        #expect(!echoFired)
        // A cough: two loud buffers, then quiet.
        let cough = [b.feed(level: -20), b.feed(level: -20), b.feed(level: -46)]
        #expect(cough == [false, false, false])
        // A real voice over it.
        var fired = false
        for _ in 0 ..< TalkBargeIn.needed { fired = b.feed(level: -18) }
        #expect(fired)
    }
}
