@testable import RealTime_Ai_Cam
import Foundation
import Testing

/// Review finding 11/04 (HIGH): Back tapped while Live Cam was still opening (the permission line, a permission
/// prompt, the model load) used to let the rest of the opening run, so the camera and mic came back on with no
/// way to stop them. Each test closes Live Cam inside one opening step and checks nothing is left running.
@MainActor
struct LiveCamCloseWhileOpeningTests {
    /// A voice that makes no sound and says it is busy until stopped (like the permission line mid-sentence).
    final class SilentVoice: LiveVoiceOutput {
        var muted = true
        var onStart: ((String, String, String) -> Void)?
        var onQuiet: (() -> Void)?
        var said: [String] = []
        private var talking = false
        var isBusy: Bool { talking }
        func say(_ english: String) { said.append(english); talking = true }
        func sayLine(_: String, lang _: String, english: String) { said.append(english); talking = true }
        func stop() { talking = false }
    }

    /// `realCamera` false: a still frame stands in (the Simulator's capture session takes ~45 s to give up), for the
    /// tests that are about the mic and the model rather than the camera.
    private func makeCall(realCamera: Bool = true) -> (LiveCallController, SilentVoice) {
        let call = LiveCallController()
        let voice = SilentVoice()
        call.voice = voice
        call.steps.releaseOther = {}
        call.steps.loadEngine = { _ in nil }   // no real model in a unit test
        call.steps.requestCamera = { true }
        call.steps.willAskPermission = { false }
        call.steps.startListener = { _ in nil }
        if !realCamera { call.camera.stillFrame = LiveCallController.noFrame }
        return (call, voice)
    }

    private func settle(_ call: LiveCallController) async {
        for _ in 0 ..< 20 { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test func openAndCloseRightAwayLeavesNothingOn() async {
        let (call, _) = makeCall()
        call.start()
        call.end()
        await settle(call)
        #expect(call.phase == .ended)
        #expect(!call.anythingRunning)
    }

    @Test func closedDuringTheCameraPromptNeverStartsTheCamera() async {
        let (call, voice) = makeCall()
        call.steps.requestCamera = { [weak call] in call?.end(); return true }
        call.start()
        await settle(call)
        #expect(call.phase == .ended)
        #expect(!call.anythingRunning)
        #expect(voice.said.isEmpty)
    }

    /// Matt 11/6: Live Cam opens silent, even the first time (iOS's own prompts say why): nothing is said before the
    /// mic starts.
    @Test func theFirstTimeNothingIsSaidBeforeTheMicStarts() async {
        let (call, voice) = makeCall(realCamera: false)
        call.steps.willAskPermission = { true }
        var listenerStarted = false
        var saidBefore: [String] = ["(not reached)"]
        call.steps.startListener = { _ in listenerStarted = true; saidBefore = voice.said; return nil }
        call.start()
        for _ in 0 ..< 40 where !listenerStarted { try? await Task.sleep(nanoseconds: 25_000_000) }
        #expect(listenerStarted)
        #expect(saidBefore.isEmpty)   // (no model in a unit test, so "couldn't start" comes after; that is a failure line)
        call.end()
        await settle(call)
        #expect(call.phase == .ended)
        #expect(!call.anythingRunning)
    }

    @Test func closedWhileTheMicIsStartingTurnsItOffAgain() async {
        let (call, _) = makeCall(realCamera: false)
        // Back lands while the mic is starting; the mic finishes starting afterwards (feed mode stands in for it).
        call.steps.startListener = { [weak call] l in
            call?.end()
            l.feedMode = true
            l.startForTest()
            return nil
        }
        call.start()
        await settle(call)
        #expect(call.phase == .ended)
        #expect(!call.listener.isRunning)
        #expect(!call.anythingRunning)
    }

    @Test func closedWhileTheModelLoadsLetsItGo() async {
        let (call, _) = makeCall(realCamera: false)
        let gate = DispatchSemaphore(value: 0)
        call.steps.loadEngine = { _ in gate.wait(); return nil }
        call.start()
        try? await Task.sleep(nanoseconds: 200_000_000)
        call.end()
        gate.signal()
        await settle(call)
        #expect(call.phase == .ended)
        #expect(!call.anythingRunning)
    }
}

/// Review finding 11/04 (HIGH): speech recognition failing the moment it starts used to restart it in a tight loop
/// (battery drain, nothing said). Now it backs off 1 s, 2 s, 5 s, then stops and says why.
@MainActor
struct LiveListenerBackoffTests {
    @Test func backsOffThenGivesUp() {
        #expect(LiveListener.retryDelay(afterQuickFailures: 1) == 1)
        #expect(LiveListener.retryDelay(afterQuickFailures: 2) == 2)
        #expect(LiveListener.retryDelay(afterQuickFailures: 3) == 5)
        #expect(LiveListener.retryDelay(afterQuickFailures: 4) == nil)
    }

    @Test func quickFailuresWaitLongerEachTimeThenStopForGood() {
        let l = LiveListener()
        var gaveUp = 0
        l.onGaveUp = { gaveUp += 1 }
        l.recognizerFailed(); #expect(l.lastRetryDelay == 1); #expect(gaveUp == 0)
        l.recognizerFailed(); #expect(l.lastRetryDelay == 2); #expect(gaveUp == 0)
        l.recognizerFailed(); #expect(l.lastRetryDelay == 5); #expect(gaveUp == 0)
        l.recognizerFailed(); #expect(gaveUp == 1); #expect(l.gaveUp)
        // Once it gave up, listening never starts again on its own.
        l.listen()
        #expect(!l.isListening)
    }

    /// Round 2: a due retry goes through the owner, who only restarts listening while it waits for a question.
    @Test func aDueRetryAsksTheOwnerFirst() async {
        let l = LiveListener()
        l.feedMode = true
        l.startForTest()
        var retries = 0
        l.onRetry = { retries += 1 }
        l.recognizerFailed()
        #expect(l.lastRetryDelay == 1)
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        #expect(retries == 1)
        #expect(!l.isListening)   // the listener did not restart on its own
    }

    /// Round 2: giving up turns the mic itself off, not just the recognizer.
    @Test func givingUpTurnsTheMicOff() async {
        let call = LiveCallController()
        call.voice = LiveCamCloseWhileOpeningTests.SilentVoice()
        call.camera.stillFrame = LiveCallController.noFrame
        call.steps.releaseOther = {}
        call.steps.loadEngine = { _ in nil }
        call.steps.requestCamera = { true }
        call.steps.willAskPermission = { false }
        call.steps.startListener = { l in l.feedMode = true; l.startForTest(); return nil }
        call.start()
        for _ in 0 ..< 10 where !call.listener.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(call.listener.isRunning)
        call.hearingGaveUp()
        #expect(!call.listener.isRunning)
        call.end()
    }

    @Test func gaveUpIsSpokenAndShownWithATypingBox() async {
        let call = LiveCallController()
        let voice = LiveCamCloseWhileOpeningTests.SilentVoice()
        call.voice = voice
        call.steps.releaseOther = {}
        call.steps.loadEngine = { _ in nil }
        call.steps.requestCamera = { true }
        call.steps.willAskPermission = { false }
        call.steps.startListener = { _ in nil }
        call.camera.stillFrame = LiveCallController.noFrame
        call.start()
        call.hearingGaveUp()
        #expect(call.hearingStopped)
        #expect(voice.said.last == LiveCamWords.cantHear)
        call.end()
        for _ in 0 ..< 10 { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(!call.anythingRunning)
    }
}
