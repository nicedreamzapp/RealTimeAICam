@testable import RealTime_Ai_Cam
import CoreGraphics
import Foundation
import Testing
import UIKit

/// Live Cam's pure logic (LiveBrain.swift, ported from Moonstone): sentences spoken as the model
/// writes them, what is remembered, what counts as a question, and when it speaks up on its own.
/// Moonstone had no tests for these; each one pins a decision Matt made while tuning it.
struct LiveSentenceStreamTests {
    @Test func speaksEachSentenceAsSoonAsItEnds() {
        var s = LiveSentenceStream()
        do { let r = s.feed("There is a blue"); #expect(r.isEmpty) }
        do { let r = s.feed("There is a blue door."); #expect(r.isEmpty) }   // the end needs the next word to be sure
        do { let r = s.feed("There is a blue door. Above it"); #expect(r == ["There is a blue door."]) }
        do { let r = s.feed("There is a blue door. Above it is"); #expect(r.isEmpty) }
        do { let r = s.feed("There is a blue door. Above it is an exit sign.", final: true); #expect((r == ["Above it is an exit sign."])) }
    }

    @Test func aPeriodInsideANumberOrBeforeLowercaseIsNotAnEnd() {
        var s = LiveSentenceStream()
        do { let r = s.feed("It is 3.5 feet away and"); #expect(r.isEmpty) }
        var t = LiveSentenceStream()
        // "Raider Day!" sign above: the sign's own "!" is not the end of the sentence.
        do { let r = t.feed("It says Have a Great Raider Day! sign above the door. Next"); #expect(r.count == 1) }
    }

    @Test func thinkBlocksMarkdownAndEmptyPiecesNeverSpoken() {
        #expect(LiveSentenceStream.cleaned("<think>hmm</think>**A door.**") == "A door.")
        #expect(LiveSentenceStream.cleaned("<think>still thinking") == "")
        var s = LiveSentenceStream()
        do { let r = s.feed("... ", final: true); #expect(r.isEmpty) }
    }

    @Test func keepsOnlyTheHonestHalfOfNoICantTell() {
        #expect(LiveSentenceStream.cleaned("No, I can't tell from here.") == "I can't tell from here.")
    }
}

struct LiveMemoryTests {
    @Test func remembersOnlyTheLastTwoFreshExchanges() {
        var m = LiveMemory()
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        m.note(question: "q1", answer: "a1", at: t0)
        m.note(question: "q2", answer: "a2", at: t0.addingTimeInterval(10))
        m.note(question: "q3", answer: "a3", at: t0.addingTimeInterval(20))
        #expect(m.exchanges.map(\.question) == ["q2", "q3"])
        #expect(m.lastAnswer == "a3")
        // Older than 90 s: not carried into a new question (the "posture" leak, 10/31).
        #expect(m.recent(at: t0.addingTimeInterval(105)).map(\.question) == ["q3"])
        #expect(m.recent(at: t0.addingTimeInterval(200)).isEmpty)
    }

    @Test func emptyAnswersAreNotRemembered() {
        var m = LiveMemory()
        m.note(question: "q", answer: "   ")
        #expect(m.exchanges.isEmpty)
    }

    @Test func aThingIsNamedOnceThenOnlyNewThingsCount() {
        var m = LiveMemory()
        m.note(question: "what do you see", answer: "Metal shelving and a forklift.")
        // shelves / shelving / shelf are one thing; people, clothes and walls are never news.
        #expect(m.newThings(["shelves", "forklift", "boat", "man", "floor"]) == ["boat"])
    }
}

struct LiveWordsTests {
    /// Matt 11/6: "It doesn't need to introduce itself or anything." None of its own lines is a welcome, a warning
    /// or an instruction about how to use it (Live Cam opens silent).
    @Test func noLineIsAWelcomeOrAnInstruction() {
        for l in LiveCamWords.indirectKeys {
            for w in ["welcome", "experimental", "double-check", "just talk", "always listening", "live cam listens"] {
                #expect(!l.lowercased().contains(w), "\(l)")
            }
        }
    }

    @Test func cameraQuestionsGetThePhotoOthersDoNot() {
        #expect(LiveWords.needsPhoto("What is in front of me?", lastUsedPhoto: false))
        #expect(LiveWords.needsPhoto("what color is this cup", lastUsedPhoto: false))
        #expect(LiveWords.needsPhoto("what forces are on this beam", lastUsedPhoto: false))
        #expect(!LiveWords.needsPhoto("how do I take an alternator off a car", lastUsedPhoto: false))
        #expect(!LiveWords.needsPhoto("what model are you", lastUsedPhoto: true))
        #expect(!LiveWords.needsPhoto("I'm gonna keep working", lastUsedPhoto: true))
        // A short pointing follow-up stays on the camera.
        #expect(LiveWords.needsPhoto("is it ripe", lastUsedPhoto: true))
    }

    @Test func endHushRepeatModesAndAsks() {
        #expect(LiveWords.turn("goodbye") == .end)
        #expect(LiveWords.turn("hold on") == .hush)
        #expect(LiveWords.turn("say that again") == .repeatLast)
        #expect(LiveWords.turn("you don't need to say that") == .stopSaying)
        #expect(LiveWords.turn("funny mode") == .mode(.funny))
        #expect(LiveWords.turn("coach me on my jump shot") == .mode(.coach))
        #expect(LiveWords.turn("what is in front of me") == .ask)
    }

    @Test func coachTakesTheGoalFromTheSentence() {
        #expect(LiveWords.modeRest("coach me on my jump shot") == "my jump shot")
        #expect(LiveWords.coachGoal("my jump shot") == "your jump shot")
        #expect(LiveWords.coachGoal("I want to get better at chess") == "chess")
    }

    @Test func judgeIgnoresFragmentsEchoesAndItsOwnVoice() {
        #expect(LiveWords.judge("the", confidence: nil, isFinal: true, lastSaid: nil) == .ignore("fragment (1 word)"))
        #expect(LiveWords.judge("listening", confidence: nil, isFinal: true, lastSaid: nil) == .ignore("screen-reader echo"))
        #expect(LiveWords.judge("a blue door with an exit sign", confidence: nil, isFinal: true,
                                lastSaid: "I see a blue door with an exit sign.") == .ignore("its own voice"))
        #expect(LiveWords.judge("What is in front of me", confidence: nil, isFinal: true, lastSaid: nil) == .answer)
        #expect(LiveWords.judge("stop", confidence: nil, isFinal: true, lastSaid: nil) == .answer)
    }

    @Test func sideTalkLongAfterItSpokeIsLeftAlone() {
        // 11/2 Matt (room chatter): right after it speaks anything is a reply; later only what's meant for it.
        #expect(LiveWords.judge("just trying to find a happy balance", confidence: nil, isFinal: true, lastSaid: nil,
                                sinceItSpoke: 5) == .answer)
        #expect(LiveWords.judge("just trying to find a happy balance", confidence: nil, isFinal: true, lastSaid: nil,
                                sinceItSpoke: 60) == .ignore("side talk"))
        #expect(LiveWords.judge("what is that over there", confidence: nil, isFinal: true, lastSaid: nil,
                                sinceItSpoke: 60) == .answer)
    }

    @Test func neverSaysThePhotoOrIntroducesItselfUnasked() {
        #expect(LiveWords.spoken("I see a door in the photo.", aboutMe: false) == "I see a door.")
        #expect(LiveWords.spoken("I'm Live Cam, running offline on your phone.", aboutMe: false) == nil)
        #expect(LiveWords.spoken("I'm Live Cam, running offline on your phone.", aboutMe: true) != nil)
        #expect(LiveWords.isAboutLiveCam("what model are you"))
    }

    @Test func looksQuestionsOnlyWhenTheyAskAboutThemselves() {
        #expect(LiveWords.isLooksQuestion("how do I look"))
        #expect(LiveWords.isLooksQuestion("rate my outfit"))
        #expect(!LiveWords.isLooksQuestion("does it look like she's crying"))
    }

    @Test func yesNoAndDetail() {
        #expect(LiveWords.isYesNo("Is the light on?"))
        #expect(!LiveWords.isYesNo("What color is it?"))
        #expect(LiveWords.needsDetail("what does the sign say"))
        #expect(!LiveWords.needsDetail("what is in front of me"))
    }

    @Test func acknowledgementNeverTheSameTwiceInARow() {
        for r in 0 ..< 20 { #expect(LiveWords.ack(after: "Okay.", random: r) != "Okay.") }
    }

    @Test func spokenDropsOh() {
        #expect(LiveWords.spoken("Oh, I see a map and a monitor.", aboutMe: false) == "I see a map and a monitor.")
        #expect(LiveWords.spoken("Ah! a dog by the door.", aboutMe: false) == "A dog by the door.")
        #expect(LiveWords.spoken("Ohio is to your left.", aboutMe: false) == "Ohio is to your left.")
        #expect(LiveWords.spoken("Oh wow, I see a map.", aboutMe: false) == "I see a map.")
    }

    @Test func newThingLineReadsNaturally() {
        #expect(LiveWords.newThingLine(["boat"]) == "I see a boat. Anything I can help with?")
        #expect(LiveWords.newThingLine(["umbrella", "boxes"]) == "I see an umbrella and boxes. Anything I can help with?")
    }
}

struct LiveTimingTests {
    @Test func aFinishedQuestionEndsSoonerThanOneWithATrailingWord() {
        #expect(LiveTiming.questionEnded(heard: true, wordsQuiet: 0.4, micQuiet: 0.55, text: "what do you see"))
        #expect(!LiveTiming.questionEnded(heard: true, wordsQuiet: 0.4, micQuiet: 0.55, text: "what do you see on the"))
        #expect(LiveTiming.questionEnded(heard: true, wordsQuiet: 1.0, micQuiet: 0, text: "what do you see on the"))
        #expect(!LiveTiming.questionEnded(heard: false, wordsQuiet: 5, micQuiet: 5, text: ""))
    }

    /// Matt 11/6: "It shouldn't stop speaking when it hears me cough... It should only stop speaking when it hears a
    /// legitimate question toward it." Sound never interrupts; only these words do.
    @Test func onlyARealQuestionOrStopWordInterrupts() {
        let saying = ["I see a white cup on a wooden desk next to a lamp."]
        func stops(_ h: String, _ c: Double? = nil, continuing: Bool = false) -> Bool {
            LiveBargeIn.shouldInterrupt(h, confidence: c, saying: saying, continuing: continuing)
        }
        // Coughs, murmurs, fillers, side talk, its own voice: it keeps talking.
        for h in ["", "huh", "um", "uh uh", "hmm", "mm hmm", "ahem", "ha ha", "yeah okay", "oh", "I'm gonna grab that",
                  "put it over there", "yeah I know right", "I see a white cup", "on a wooden desk next to", "white cup lamp"] {
            #expect(!stops(h), "should not interrupt: \(h)")
        }
        #expect(!stops("what is that thing", 0.1))   // too unsure
        #expect(!stops("what is"))                    // not three words yet
        // Real questions and stop words: it stops.
        for h in ["what is that", "wait stop", "wait", "stop", "hold on", "how do I fix this", "can you read this sign",
                  "um what color is the lamp", "tell me about the cup", "hey", "is that a dog"] {
            #expect(stops(h), "should interrupt: \(h)")
        }
        // Right after their own question: they weren't done, two real words carry on.
        #expect(stops("in this room", continuing: true))
        #expect(!stops("um", continuing: true))
    }
}

struct LiveProactiveTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func speaksOnlyWhenTheViewReallyChanged() {
        var w = LiveProactive()
        let dark = [UInt8](repeating: 20, count: 256), bright = [UInt8](repeating: 200, count: 256)
        let near = [UInt8](repeating: 25, count: 256)
        w.described(dark)
        do { let r = w.shouldLook(thumb: near, at: t0, quiet: true); #expect(!r) }        // someone moving, same room
        do { let r = w.shouldLook(thumb: bright, at: t0, quiet: true); #expect(r) }       // a new view
        do { let r = w.shouldLook(thumb: bright, at: t0, quiet: false); #expect(!r) }     // never over the person
    }

    @Test func goesQuietAfterTwoUnansweredUntilABigChange() {
        var w = LiveProactive()
        let a = [UInt8](repeating: 20, count: 256), b = [UInt8](repeating: 40, count: 256), c = [UInt8](repeating: 120, count: 256)
        w.described(a)
        w.commented(at: t0); w.commented(at: t0)
        let later = t0.addingTimeInterval(10)
        do { let r = w.shouldLook(thumb: b, at: later, quiet: true); #expect(!r) }   // changed, but not a lot
        do { let r = w.shouldLook(thumb: c, at: later, quiet: true); #expect(r) }    // a big change
    }

    @Test func checksInOnlyAfterALongQuietAndNeverWhenOff() {
        var w = LiveProactive()
        #expect(!w.shouldCheckIn(at: t0.addingTimeInterval(60), quietSince: t0))
        #expect(w.shouldCheckIn(at: t0.addingTimeInterval(91), quietSince: t0))
        w.enabled = false
        #expect(!w.shouldCheckIn(at: t0.addingTimeInterval(500), quietSince: t0))
    }

    @Test func modesRideOnTheQuestion() {
        #expect(LiveMode.analyze.maxTokens > LiveMode.normal.maxTokens)
        #expect(LiveMode.coach.ask("on my jump shot", coachGoal: "your jump shot").contains("your jump shot"))
        #expect(LiveMode.funny.ask("what is this", coachGoal: nil).contains("funny"))
    }
}

/// Matt 11/6: "I don't want it to keep asking if it can help constantly, and not to repeat itself."
struct LiveSayGuardTests {
    @Test func helpIsOfferedOncePerVisit() {
        var g = LiveSayGuard()
        #expect(g.newThingFormat == LiveCamWords.newThing)
        #expect(g.vet("Need a hand with that?") == "Need a hand with that?")
        g.note(LiveCamWords.helpOffer)
        #expect(g.helpOffered)
        #expect(g.vet("Anything else I can help with?") == nil)
        #expect(g.vet("Need a hand with anything?") == nil)
        #expect(g.newThingFormat == LiveCamWords.newThingPlain)
        g.note("I see a boat.")
        #expect(g.newThingFormat == LiveCamWords.newThingThere)   // never "I see" twice in a row
        #expect(!LiveWords.isHelpOffer(LiveCamWords.newThingPlain))
        #expect(LiveWords.isHelpOffer(LiveCamWords.newThing))
    }

    @Test func aSentenceAlreadySaidIsDropped() {
        var g = LiveSayGuard()
        g.note("The cup is white.")
        #expect(g.vet("The cup is white.") == nil)
        #expect(g.vet("the cup is WHITE") == nil)
        #expect(g.vet("The mug is blue.") == "The mug is blue.")
    }

    @Test func aLoopingSentenceIsCut() {
        let s = "The cup is on the table and the cup is on the table and the cup is on the table"
        #expect(LiveSayGuard.cutLoop(s) == "The cup is on the table.")
        #expect(LiveSayGuard.cutLoop("A red mug sits next to a blue bowl on a wooden desk.") == "A red mug sits next to a blue bowl on a wooden desk.")
        let g = LiveSayGuard()
        #expect(g.vet(s) == "The cup is on the table.")
    }

    @Test func noTwoLinesInARowOpenTheSameWay() {
        var g = LiveSayGuard()
        g.note("I see a book on the desk.")
        #expect(g.vet("I see a red cup.") == "There's a red cup.")
        #expect(g.vet("I see two cups.") == "There are two cups.")
        #expect(g.vet("I see that the light is on.") == "The light is on.")
        g.note("There's a red cup.")
        #expect(g.vet("I see a lamp.") == "I see a lamp.")
    }

    @Test func checkInsNeverRepeatBackToBack() {
        var r = LiveRotation()
        let lines = LiveWords.checkIns
        var picked: [String] = []
        for i in 0 ..< 40 { picked.append(r.next(from: lines, random: i * 7 + 3)!) }
        for i in 1 ..< picked.count { #expect(picked[i] != picked[i - 1]) }
        #expect(Set(picked.prefix(lines.count)).count == lines.count)   // all used before any comes back
        let noHelp = lines.filter { !LiveWords.isHelpOffer($0) }
        #expect(!noHelp.isEmpty && noHelp.count < lines.count)
        var r2 = LiveRotation()
        var last = ""
        for i in 0 ..< 12 { let p = r2.next(from: noHelp, random: i)!; #expect(p != last); #expect(!LiveWords.isHelpOffer(p)); last = p }
    }
}

/// Matt 11/6: "Live cam needs to have a flashlight", by voice too, handled on the phone.
struct LiveFlashlightTests {
    @Test func spokenLightCommands() {
        for q in ["turn on the light", "turn on the flashlight", "lights on", "flashlight on", "can you turn the flashlight on",
                  "it's dark I need some light", "turn the light on please"] {
            #expect(LiveWords.lightCommand(q) == .some(true), "on: \(q)")
        }
        for q in ["lights off", "turn off the flashlight", "flashlight off", "turn the light off", "kill the light"] {
            #expect(LiveWords.lightCommand(q) == .some(false), "off: \(q)")
        }
        #expect(LiveWords.lightCommand("flashlight") == .some(nil))   // switch it
        for q in ["is the light on", "what color is the light", "the light is too bright", "do you see a flashlight",
                  "where is my flashlight", "how do I fix this", "turn left"] {
            #expect(LiveWords.lightCommand(q) == nil, "not a command: \(q)")
        }
        #expect(LiveWords.turn("lights off") == .light(false))
        #expect(LiveWords.judge("lights on", confidence: nil, isFinal: true, lastSaid: nil, sinceItSpoke: 100) == .answer)
        #expect(LiveBargeIn.shouldInterrupt("lights off", confidence: nil, saying: ["The cup is white."]))
    }
}

/// Matt 11/6: three orb looks nobody can confuse, and the turn tick is a short soft tone made on the phone.
struct LiveTurnSignalTests {
    @Test func eachPhaseHasItsOwnLook() {
        #expect(LiveOrb.look(.listening, muted: false) == .yourTurn)
        #expect(LiveOrb.look(.listening, muted: true) == .muted)
        #expect(LiveOrb.look(.thinking, muted: false) == .looking)
        #expect(LiveOrb.look(.speaking, muted: false) == .talking)
        #expect(LiveOrb.look(.loading, muted: false) == .waiting)
        #expect(LiveOrb.turnColor != LiveOrb.lookColor)
    }

}

/// The 11/6 review's five fixes.
struct LiveReviewRound1Tests {
    @Test func answersToQuestionsAreNeverBlockedAsSaidBefore() {
        var g = LiveSayGuard()
        g.beginTurn(); g.note("Yes.")
        g.beginTurn()
        #expect(g.vet("Yes.", prompted: true) == "Yes.")                  // "Is the door open?" "Yes." after "Yes."
        g.note("Yes.")
        #expect(g.vet("Yes.", prompted: true) == nil)                     // twice inside one answer: the model looping
        g.beginTurn(); g.note("There is a red boat on the water.")
        g.beginTurn()
        #expect(g.vet("There is a red boat on the water.", prompted: false) == nil)   // unasked and 5+ words: said before
        #expect(g.vet("There is a red boat on the water.", prompted: true) != nil)    // asked: always answered
        #expect(g.vet("Need anything?", prompted: false) == "Need anything?")         // short lines are never blocked
        #expect(LiveWords.turn("can you repeat that") == .repeatLast)
        #expect(LiveWords.turn("sorry could you say that again") == .repeatLast)
    }

    @Test func aQuestionOnTheSameTopicIsNotAnEcho() {
        #expect(LiveBargeIn.shouldInterrupt("what color is the cup", confidence: nil, saying: ["The cup is red."]))
        #expect(!LiveBargeIn.shouldInterrupt("the cup is red", confidence: nil, saying: ["The cup is red."]))
        #expect(!LiveBargeIn.shouldInterrupt("cup is red and", confidence: nil, saying: ["The cup is red and shiny."]))
    }

    @Test func stopWordsCountAnywhereInTheNewestWords() {
        #expect(LiveBargeIn.shouldInterrupt("the cup is red wait", confidence: nil, saying: ["The cup is red and shiny."]))
        #expect(LiveBargeIn.shouldInterrupt("hold on", confidence: nil, saying: ["The cup is on the table."]))
        #expect(LiveBargeIn.shouldInterrupt("okay okay stop", confidence: nil, saying: ["The cup is red."]))
    }

    @Test func spanishStopAndQuestionWords() {
        for h in ["espera", "para", "oye", "un momento", "qué es eso", "dime qué ves", "cómo lo arreglo", "puedes leer esto"] {
            #expect(LiveBargeIn.shouldInterrupt(h, confidence: nil, saying: ["La taza es blanca."], lang: "es-ES"), "should interrupt: \(h)")
        }
        for h in ["eh este", "pues voy a la tienda", "la taza es blanca", "jaja", "esto es para mi mamá"] {
            #expect(!LiveBargeIn.shouldInterrupt(h, confidence: nil, saying: ["La taza es blanca."], lang: "es-ES"), "should not: \(h)")
        }
    }

    @Test func aBargedInQuestionLeavesOutItsOwnEcho() {
        #expect(LiveBargeIn.stripLeadingEcho("the cup is red what is that", saying: ["The cup is red."]) == "what is that")
        #expect(LiveBargeIn.stripLeadingEcho("what is that", saying: ["The cup is red."]) == "what is that")
    }
}

/// The 11/6 review, round 2.
struct LiveReviewRound2Tests {
    @Test func itsOwnLightLineHeardBackNeverTogglesTheLight() {
        #expect(!LiveBargeIn.shouldInterrupt("flashlight on", confidence: nil, saying: ["Flashlight, on"]))
        #expect(!LiveBargeIn.shouldInterrupt("turn on the flashlight", confidence: nil,
                                             saying: ["You can turn on the flashlight in the corner."]))
        #expect(!LiveBargeIn.shouldInterrupt("hold on", confidence: nil, saying: ["Hold on, let me look."]))
        #expect(LiveBargeIn.shouldInterrupt("lights off", confidence: nil, saying: ["The cup is white."]))
    }

    @Test func onlyAnEchoAtTheStartIsStrippedByItsText() {
        let saying = ["The cup's red handle is on the left."]
        #expect(LiveBargeIn.stripLeadingEcho("The cup's red handle what is that", saying: saying) == "what is that")
        #expect(LiveBargeIn.stripLeadingEcho("what is that, the cup's red handle", saying: saying) == "what is that, the cup's red handle")
        #expect(LiveBargeIn.stripLeadingEcho("what is that", saying: saying) == "what is that")
    }

    @Test func aStopWordAnywhereInTheUtteranceStopsIt() {
        #expect(LiveBargeIn.shouldInterrupt("wait what is the red one over there by the door", confidence: nil, saying: ["I see a lamp."]))
        #expect(LiveBargeIn.shouldInterrupt("okay so um wait", confidence: nil, saying: ["I see a lamp."]))
    }

    @Test func commonSpanishWordsAloneAreNotAQuestion() {
        let s = ["La taza es blanca."]
        #expect(!LiveBargeIn.shouldInterrupt("que bueno que viniste", confidence: nil, saying: s, lang: "es-MX"))
        #expect(!LiveBargeIn.shouldInterrupt("esta casa está bonita", confidence: nil, saying: s, lang: "es-MX"))
        #expect(LiveBargeIn.shouldInterrupt("¿que es eso de ahí?", confidence: nil, saying: s, lang: "es-MX"))
        #expect(LiveBargeIn.shouldInterrupt("qué es eso", confidence: nil, saying: s, lang: "es-MX"))
        #expect(LiveBargeIn.shouldInterrupt("donde esta mi taza", confidence: nil, saying: s, lang: "es-MX"))   // two cues
    }

    @Test func theBottomRowFitsFrom320ToTheUnfoldedDuo() {
        for w in [320.0, 375, 390, 440, 669, 951] as [CGFloat] {
            for n in [2, 3, 4] {
                let r = LiveCamView.bottomRow(width: w, count: n)
                let row = CGFloat(n) * (r.size + 8) + CGFloat(n - 1) * r.spacing
                #expect(row <= min(w, 640) - 32 + 0.5, "row \(row) at \(w) with \(n)")
                #expect(r.size >= 56)
            }
        }
    }

    @Test func theTorchFollowsTheCameraNotTheRequest() async {
        let cam = LiveCamera()
        cam.stillFrame = LiveCallController.noFrame
        let seen = TorchLog()
        cam.onTorch = { seen.add($0) }
        cam.torchSetter = { _ in false }              // the torch fails to turn on
        cam.setTorch(true)
        await seen.wait(1)
        #expect(seen.values == [false])
        cam.torchSetter = { $0 }                      // works now
        cam.setTorch(true)
        await seen.wait(2)
        cam.interruptionBegan()                       // iOS pauses the camera: the light is off
        await seen.wait(3)
        cam.reapplyTorch()                            // back after the restart
        await seen.wait(4)
        #expect(seen.values == [false, true, false, true])
    }
}

final class TorchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [Bool] = []
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return v }
    func add(_ b: Bool) { lock.lock(); v.append(b); lock.unlock() }
    func wait(_ n: Int) async { for _ in 0 ..< 200 where values.count < n { try? await Task.sleep(nanoseconds: 10_000_000) } }
}

/// The 11/6 review, round 3: the light never stays on after Back, and its reports match what really happened.
struct LiveReviewRound3Tests {
    @Test func aTorchTapQueuedBeforeBackNeverLeavesTheLightOn() async {
        let cam = LiveCamera()
        cam.stillFrame = LiveCallController.noFrame
        let seen = TorchLog()
        cam.onTorch = { seen.add($0) }
        cam.torchSetter = { $0 }
        cam.setTorch(true)   // tapped
        cam.stop()           // Back, right after
        await seen.wait(2)
        #expect(seen.values.last == false)
    }

    @Test func turningItOnReportsOnOnlyOnce() async {
        let cam = LiveCamera()
        cam.stillFrame = LiveCallController.noFrame
        let seen = TorchLog()
        cam.onTorch = { seen.add($0) }
        cam.torchSetter = { $0 }
        cam.setTorch(true)
        await seen.wait(1)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(!seen.values.contains(false))   // never an "off" on the way to on (it said "isn't working")
        #expect(seen.values.last == true)
    }
}

/// Live Cam money (merged 11/6) keeps the 11/6 rules: its counting line takes turns, and an answer passes the
/// repeat guard as is.
struct LiveMoneyRulesTests {
    @Test func countingLinesTakeTurnsAndNeverOfferHelp() {
        var r = LiveRotation()
        var last = ""
        for i in 0 ..< 9 {
            let l = r.next(from: LiveCamWords.countingLines, random: i)!
            #expect(l != last); #expect(!LiveWords.isHelpOffer(l)); last = l
        }
        #expect(Set(LiveCamWords.countingLines.map(LiveSayGuard.opening)).count == LiveCamWords.countingLines.count)
    }

    @Test func aMoneyAnswerPassesTheGuardUnchangedEvenIfSaidBefore() {
        var g = LiveSayGuard()
        g.beginTurn(); g.note("I count 3 bills, $45 total.")
        g.beginTurn()
        #expect(g.vet("I count 3 bills, $45 total.", prompted: true) == "I count 3 bills, $45 total.")
    }
}

/// Matt 11/6 "it stalls": within about half a second of the voice stopping, the orb already shows "looking".
struct LiveNoDeadAirTests {
    @Test func lookingShowsWithinHalfASecondOfTheVoiceStopping() {
        // The listener checks every 40 ms, so the worst case is the threshold plus one check.
        #expect(LiveTiming.showLookingAfter + 0.04 <= 0.5)
        #expect(LiveTiming.soundsDone(wordsQuiet: 0.4, micQuiet: 0.4))
        #expect(!LiveTiming.soundsDone(wordsQuiet: 0.4, micQuiet: 0.2))   // still talking
        #expect(!LiveTiming.soundsDone(wordsQuiet: 0.1, micQuiet: 0.6))   // words still coming in
        #expect(LiveTiming.soundsDone(wordsQuiet: 0.8, micQuiet: 0.0))    // a noisy room: the words stopped
        // It shows before the question is formally over, never after.
        #expect(LiveTiming.showLookingAfter < LiveTiming.audioQuietComplete)
    }
}

/// Matt 11/6: a goal for the visit ("I'm changing a tire"), its steps, and how it ends.
struct LiveGoalTests {
    @Test func aGoalIsHeardInEverydayWords() {
        #expect(LiveGoal.detect("I'm changing a tire") == "changing a tire")
        #expect(LiveGoal.detect("help me fix my sink") == "fix your sink")
        #expect(LiveGoal.detect("Can you help me put this shelf together?") == "put this shelf together")
        #expect(LiveGoal.detect("I'm working on my bike") == "your bike")
        #expect(LiveGoal.detect("I'm trying to bake bread") == "bake bread")
        #expect(LiveGoal.detect("walk me through replacing a light switch") == "replacing a light switch")
        #expect(LiveGoal.detect("I'm doing my taxes") == "doing your taxes")
    }

    @Test func smallTalkAndQuestionsAreNotGoals() {
        for q in ["I'm tired", "I'm doing good", "I'm gonna keep working", "I'm feeling sick", "how do I look", "what is that",
                  "help me see", "I'm just sitting here", "help me with this", "I'm fine thanks", "done", "never mind"] {
            #expect(LiveGoal.detect(q) == nil, "not a goal: \(q)")
        }
    }

    @Test func doneNeverMindAndNewThingClearIt() {
        for q in ["done", "I'm done", "all done", "never mind", "new thing", "let's do something else", "forget it", "I fixed it"] {
            #expect(LiveGoal.clears(q), "should clear: \(q)")
        }
        for q in ["done, what's next", "next", "what is that", "okay done with that next"] { #expect(!LiveGoal.clears(q), "should not clear: \(q)") }
    }

    @Test func nextStepWords() {
        #expect(LiveGoal.wantsNext("what's next", askedReady: false))
        #expect(LiveGoal.wantsNext("okay got it", askedReady: false) == false)
        #expect(LiveGoal.wantsNext("got it", askedReady: false))
        #expect(LiveGoal.wantsNext("then what", askedReady: false))
        #expect(!LiveGoal.wantsNext("yes", askedReady: false))
        #expect(LiveGoal.wantsNext("yes", askedReady: true))   // after "Ready for the next step?"
        #expect(!LiveGoal.wantsNext("what color is the jack", askedReady: true))
    }

    @Test func theRiderAsksForTheNextStepOnly() {
        var g = LiveGoal.State(task: "changing a tire")
        let first = LiveGoal.rider(g, next: true)
        #expect(first.contains("changing a tire") && first.contains("step 1"))
        g.lastStep = "Loosen the lug nuts a half turn before you jack it up."; g.step = 2
        let second = LiveGoal.rider(g, next: true)
        #expect(second.contains("step 2") && second.contains("Loosen the lug nuts"))
        #expect(second.count < 400)   // the 2B model: keep it short
        #expect(!LiveGoal.rider(g, next: false).contains("step 2"))
    }

    @Test func goalCheckInsVaryAndNeverOfferHelp() {
        var r = LiveRotation()
        var last = ""
        for i in 0 ..< 15 {
            let l = r.next(from: LiveGoal.checkIns, random: i * 3)!
            #expect(l != last); #expect(!LiveWords.isHelpOffer(l)); last = l
        }
        #expect(LiveGoal.checkIns.contains("Ready for the next step?"))
    }
}

/// Steps 2-5, review round 1 (11/6).
struct LiveStepsReview1Tests {
    @Test func itsOwnNextLineAndAStrayOkNeverAdvanceAStep() {
        let heard = LiveWords.normalize("say next when you're ready").split(separator: " ").map(String.init)
        #expect(LiveBargeIn.withoutEcho(heard, saying: ["Say next when you're ready."]).isEmpty)
        #expect(!LiveGoal.wantsNext("ok", askedReady: false))
        #expect(!LiveGoal.wantsNext("okay", askedReady: false))
        #expect(LiveGoal.wantsNext("ok", askedReady: true))
        var g = LiveGoal.State(task: "changing a tire")
        g.askedReadyAt = Date().addingTimeInterval(-11)
        #expect(!g.askedRecently())
        g.askedReady = true
        #expect(g.askedRecently())
    }

    @Test func aQuestionNeverStartsAGoalAndAStepNeverReplacesIt() {
        #expect(LiveGoal.detect("I'm holding a can, what is it?") == nil)
        #expect(LiveGoal.detect("help me find where the leak is") == nil)
        #expect(LiveGoal.detect("I'm changing a tire") == "changing a tire")
        #expect(!LiveGoal.isExplicitNewTask("I'm putting the spare on"))
        #expect(LiveGoal.isExplicitNewTask("now I need to fix the faucet"))
    }

    @Test func zoomNeverShowsHalfOnATwoLensPhone() {
        #expect(LiveCamera.oneX(hasUltraWide: false, firstSwitchOver: 2) == 1)   // wide + tele: 1x is the wide lens
        #expect(LiveCamera.oneX(hasUltraWide: true, firstSwitchOver: 2) == 2)    // ultra wide + wide: 1x is the wide
        #expect(LiveCamera.oneX(hasUltraWide: true, firstSwitchOver: nil) == 1)
    }
}

/// Goal follow-ups (Matt 11/6).
struct LiveGoalFollowUpTests {
    @Test func aNewTaskMidGoalIsANewGoal() {
        #expect(LiveGoal.detect("Now I need to fix the faucet") == "fix the faucet")
        #expect(LiveGoal.asksForTask("Now I need to fix the faucet"))
        #expect(LiveGoal.asksForTask("okay help me hang this picture"))
        #expect(!LiveGoal.asksForTask("I'm putting the spare on"))   // a step of the tire
        #expect(LiveGoal.detect("I'm changing a tire") == "changing a tire")
    }

    @Test func okRightAfterReadyAdvances() {
        var g = LiveGoal.State(task: "changing a tire")
        g.askedReady = true
        #expect(g.askedRecently())
        #expect(LiveGoal.wantsNext("ok", askedReady: g.askedRecently()))
        #expect(LiveWords.isEcho("ok"))   // why the controller lets it through only inside the window
    }

    @Test func aLoneEchoedNextIsIgnored() {
        #expect(LiveGoal.isEchoTail(["next"], speaking: true, sinceItSpoke: 5))
        #expect(LiveGoal.isEchoTail(["next"], speaking: false, sinceItSpoke: 0.4))
        #expect(!LiveGoal.isEchoTail(["next"], speaking: false, sinceItSpoke: 2))
        #expect(!LiveGoal.isEchoTail(["what", "next"], speaking: false, sinceItSpoke: 0.4))
    }
}

/// Goal follow-ups 2 (review 11/6): a question about the job never replaces the job.
struct LiveGoalFollowUp2Tests {
    private var tire: LiveGoal.State {
        var g = LiveGoal.State(task: "changing a tire")
        g.lastStep = "Loosen the lug nuts a half turn before you jack it up."
        return g
    }

    @Test func questionsAboutTheJobKeepTheJob() {
        #expect(!LiveGoal.switchesGoal(tire, "how do I loosen the lug nuts?"))
        #expect(!LiveGoal.switchesGoal(tire, "I need to get the hubcap off"))
        #expect(!LiveGoal.switchesGoal(tire, "now I need to tighten the lug nuts"))   // shares the last step's words
        #expect(LiveGoal.asksForTask("I need to get the hubcap off"))                  // so it is answered, not a step
    }

    @Test func anotherJobSwitches() {
        #expect(LiveGoal.switchesGoal(tire, "Now I need to fix the faucet"))
        #expect(LiveGoal.switchesGoal(tire, "let's do something else"))
    }

    @Test func aQuickOkAfterReadyIsNotAnEchoTail() {
        var g = tire
        g.askedReady = true
        // The controller skips the echo-tail rule for "ok" inside the window; the tail rule alone would drop it.
        #expect(LiveGoal.isEchoTail(["ok"], speaking: false, sinceItSpoke: 0.3))
        #expect(g.askedRecently() && LiveGoal.wantsNext("ok", askedReady: g.askedRecently()))
    }
}

/// Goal follow-ups 3 (review 11/6).
struct LiveGoalFollowUp3Tests {
    @Test func onlyNowOrNextSwitchesAndNeverAQuestion() {
        var g = LiveGoal.State(task: "changing a tire")
        g.lastStep = "Loosen the lug nuts a half turn before you jack it up."
        #expect(!LiveGoal.switchesGoal(g, "Okay, how do I get the hubcap off?"))
        #expect(!LiveGoal.switchesGoal(g, "so I need to fix the faucet"))
        #expect(LiveGoal.switchesGoal(g, "Now I need to fix the faucet"))
        #expect(!LiveGoal.switchesGoal(g, "now how do I fix the faucet"))
    }

    @Test func aQuickOkCountsOnlyOnceItStoppedTalking() {
        #expect(!LiveGoal.quickOkCounts(["ok"], askedRecently: true, speaking: true, sinceItSpoke: 3, lastSaid: "Ready for the next step?"))
        #expect(LiveGoal.quickOkCounts(["ok"], askedRecently: true, speaking: false, sinceItSpoke: 0.3, lastSaid: "Ready for the next step?"))
        #expect(!LiveGoal.quickOkCounts(["okay"], askedRecently: true, speaking: false, sinceItSpoke: 0.3, lastSaid: "Okay. What's the new thing?"))
        #expect(!LiveGoal.quickOkCounts(["ok"], askedRecently: false, speaking: false, sinceItSpoke: 3, lastSaid: nil))
    }
}

/// Matt 11/09: always watching, only new things, once each; he speaks = priority.
struct LiveNoveltyTests {
    private func memory(_ told: [String]) -> LiveMemory {
        var m = LiveMemory(); m.noteThings(told); return m
    }

    @Test func whatWasThereAtTheStartIsNeverNew() {
        var n = LiveNovelty()
        let m = memory([])
        do { let r1 = n.observe(["chair", "table"]) { !m.newThings([$0]).isEmpty }.isEmpty; #expect(r1) }   // the baseline
        do { let r2 = n.observe(["chair", "table"]) { !m.newThings([$0]).isEmpty }.isEmpty; #expect(r2) }
        do { let r3 = n.observe(["chair", "table"]) { !m.newThings([$0]).isEmpty }.isEmpty; #expect(r3) }
    }

    @Test func aNewThingNeedsTwoChecksInARow() {
        var n = LiveNovelty()
        let m = memory([])
        _ = n.observe(["table"]) { !m.newThings([$0]).isEmpty }
        do { let r4 = n.observe(["table", "dog"]) { !m.newThings([$0]).isEmpty }.isEmpty; #expect(r4) }       // one check: maybe a blur
        do { let r5 = n.observe(["table"]) { !m.newThings([$0]).isEmpty }.isEmpty; #expect(r5) }              // gone: starts over
        do { let r6 = n.observe(["table", "dog"]) { !m.newThings([$0]).isEmpty }.isEmpty; #expect(r6) }
        do { let r7 = n.observe(["table", "dog"]) { !m.newThings([$0]).isEmpty } == ["dog"]; #expect(r7) }    // two in a row
    }

    @Test func aNewThingIsAnnouncedOnce() {
        var n = LiveNovelty()
        var m = memory([])
        _ = n.observe([]) { !m.newThings([$0]).isEmpty }
        _ = n.observe(["dog"]) { !m.newThings([$0]).isEmpty }
        do { let r8 = n.observe(["dog"]) { !m.newThings([$0]).isEmpty } == ["dog"]; #expect(r8) }
        n.announced("dog", at: Date()); m.noteThings(["dog"])
        for _ in 0 ..< 4 { let r9 = n.observe(["dog"]) { !m.newThings([$0]).isEmpty }.isEmpty; #expect(r9) }
    }

    @Test func aQuestionPausesTheWatch() {
        var n = LiveNovelty()
        let m = memory([])
        _ = n.observe([]) { !m.newThings([$0]).isEmpty }
        n.paused = true
        do { let r10 = n.observe(["car"]) { !m.newThings([$0]).isEmpty }.isEmpty; #expect(r10) }
        do { let r11 = n.observe(["car"]) { !m.newThings([$0]).isEmpty }.isEmpty; #expect(r11) }
        #expect(!n.canSpeak(at: Date()))
        n.paused = false
        do { let r12 = n.observe(["car"]) { !m.newThings([$0]).isEmpty }.isEmpty; #expect(r12) }   // the count starts after the answer
        do { let r13 = n.observe(["car"]) { !m.newThings([$0]).isEmpty } == ["car"]; #expect(r13) }
    }

    @Test func linesKeepAGap() {
        var n = LiveNovelty()
        let t = Date()
        #expect(n.canSpeak(at: t))
        n.spoke(at: t)
        #expect(!n.canSpeak(at: t.addingTimeInterval(LiveNovelty.minGap - 1)))
        #expect(n.canSpeak(at: t.addingTimeInterval(LiveNovelty.minGap + 0.1)))
    }

    @Test func theSameTableWallChairOrPersonIsNeverNewAgain() {
        let m = memory(["A kitchen with a wooden table, two chairs and a window."])
        #expect(m.newThings(["table", "chair", "chairs"]).isEmpty)
        #expect(m.newThings(["wall", "wooden wall"]).isEmpty)                 // walls are never news
        #expect(m.newThings(["man", "person", "woman in a blue shirt"]).isEmpty) // the same person is never re-announced
        #expect(m.newThings(["dog"]) == ["dog"])
        #expect(m.addsNothing("There is a wooden table and two chairs."))
        #expect(!m.addsNothing("A dog is lying under the table."))
    }

    @Test func aNewRoomStartsOver() {
        var m = memory(["table"])
        var n = LiveNovelty()
        _ = n.observe(["table"]) { !m.newThings([$0]).isEmpty }
        m.forgetThings(); n.reset()
        #expect(!m.newThings(["table"]).isEmpty)
        do { let r14 = n.observe(["tree", "street"]) { !m.newThings([$0]).isEmpty }.isEmpty; #expect(r14) }   // the new baseline
    }

    @Test func theOpeningReadIsNeverAGreetingOrAQuestion() {
        #expect(LiveWords.isOpeningReadable("A kitchen with a table, two chairs and a window."))
        #expect(!LiveWords.isOpeningReadable("Hey there, how's it going?"))
        #expect(!LiveWords.isOpeningReadable("Welcome to Live Cam."))
        #expect(!LiveWords.isOpeningReadable("Anything I can help with?"))
        #expect(!LiveWords.isOpeningReadable("It's experimental, so double-check anything important."))
        #expect(LiveWords.wantsEverything("describe everything again"))
        #expect(!LiveWords.wantsEverything("what do you see"))
    }
}

/// Review 11/09: someone arriving is said once, the same person staying is not; turning around in one room is not
/// a new room.
struct LiveNoveltyPeopleAndRoomTests {
    @Test func someoneArrivingIsSaidOnceAfterTwoChecks() {
        var n = LiveNovelty()
        do { let r15 = !n.someoneArrived(1); #expect(r15) }                      // before the baseline: one person already here
        _ = n.observe(["table"]) { _ in true }             // baseline
        do { let r16 = !n.someoneArrived(1); #expect(r16) }                      // the same person staying
        do { let r17 = !n.someoneArrived(2); #expect(r17) }                      // one check: maybe a mistake
        do { let r18 = n.someoneArrived(2); #expect(r18) }                       // two in a row: said
        do { let r19 = !n.someoneArrived(2); #expect(r19) }                      // and not again
        do { let r20 = !n.someoneArrived(1); #expect(r20) }
    }

    @Test func turningAroundInTheSameRoomIsNotANewRoom() {
        var n = LiveNovelty()
        _ = n.observe(["table", "chair", "lamp"]) { _ in true }
        do { let r21 = !n.looksLikeNewRoom(["table", "chair", "lamp"], bigChange: false); #expect(r21) }
        do { let r22 = !n.looksLikeNewRoom(["sofa", "tv", "rug"], bigChange: true); #expect(r22) }       // the other side of the room...
        do { let r23 = !n.looksLikeNewRoom(["table", "chair", "lamp"], bigChange: true); #expect(r23) }  // ...and back: seen before
        do { let r24 = !n.looksLikeNewRoom(["sofa", "tv", "rug"], bigChange: true); #expect(r24) }       // all seen in this room now
    }

    @Test func aNewRoomNeedsSeveralChecks() {
        var n = LiveNovelty()
        do { let r = n.looksLikeNewRoom(["table", "chair", "lamp"], bigChange: false); #expect(!r) }
        _ = n.observe(["table", "chair", "lamp"]) { _ in true }
        do { let r = n.looksLikeNewRoom(["tree", "car", "street"], bigChange: true); #expect(!r) }
        do { let r = n.looksLikeNewRoom(["tree", "car", "street"], bigChange: true); #expect(!r) }
        do { let r = n.looksLikeNewRoom(["tree", "car", "street"], bigChange: true); #expect(r) }   // three in a row
        #expect(!n.baselined)   // and it starts over
    }
}

/// Review 11/09: one thing, two names, told once.
struct LiveMemorySynonymTests {
    @Test func twoNamesForOneThingAreOneThing() {
        var m = LiveMemory()
        m.noteThings(["tv", "desk", "laptop"])
        #expect(m.newThings(["television", "table", "computer"]).isEmpty)
        #expect(m.newThings(["dog"]) == ["dog"])
    }
}

/// Review 11/09: plural names map too, and "see anything" is only the bare question.
struct LiveMemoryPluralSynonymTests {
    @Test func pluralNamesMapToOneThing() {
        var m = LiveMemory()
        m.noteThings(["tv", "sofa", "computer", "screen"])
        #expect(m.newThings(["televisions", "couches", "laptops", "monitors"]).isEmpty)
    }

    @Test func seeAnythingOnlyAsTheBareQuestion() {
        #expect(LiveWords.isSeeAgain("Do you see anything?"))
        #expect(LiveWords.isSeeAgain("see anything new"))
        #expect(!LiveWords.isSeeAgain("can you see anything written on the label"))
    }
}
