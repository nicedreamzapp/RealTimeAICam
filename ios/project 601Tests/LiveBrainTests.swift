@testable import RealTime_Ai_Cam
import Foundation
import Testing

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

    @Test func newThingLineReadsNaturally() {
        #expect(LiveWords.newThingLine(["boat"]) == "Oh, I see a boat now.")
        #expect(LiveWords.newThingLine(["umbrella", "boxes"]) == "Oh, I see an umbrella and boxes now.")
    }
}

struct LiveTimingTests {
    @Test func aFinishedQuestionEndsSoonerThanOneWithATrailingWord() {
        #expect(LiveTiming.questionEnded(heard: true, wordsQuiet: 0.4, micQuiet: 0.55, text: "what do you see"))
        #expect(!LiveTiming.questionEnded(heard: true, wordsQuiet: 0.4, micQuiet: 0.55, text: "what do you see on the"))
        #expect(LiveTiming.questionEnded(heard: true, wordsQuiet: 1.0, micQuiet: 0, text: "what do you see on the"))
        #expect(!LiveTiming.questionEnded(heard: false, wordsQuiet: 5, micQuiet: 5, text: ""))
    }

    @Test func bargeInNeedsAVoiceClearlyAboveTheEcho() {
        var b = LiveBargeIn()
        for _ in 0 ..< 10 { let r = b.feed(level: -45); #expect(!r) }   // its own echo, quiet
        do { let r = b.feed(level: -20); #expect(!(r)) }; do { let r = b.feed(level: -20); #expect(!(r)) }; do { let r = b.feed(level: -20); #expect(!(r)) }
        let last = b.feed(level: -20); #expect(last)   // a quarter second of a real voice
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
