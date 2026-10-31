import AVFoundation
import Foundation

// Talk mode, tested on a real phone with nobody talking and no sound.
//
// Debug builds only. `-rtcamTalkFeed` (with `-rtcamOpenTalk`) replaces the
// microphone with the recorded questions in Documents/talk-feed (q1.wav,
// q2.wav, ... in name order), pushed into TalkListener in real time, 1024
// frames at a time, with silence in between, exactly where the mic tap would
// hand them over. So the recognizer, the 1.2 s end of a question, memory,
// streaming and turn taking all run for real. `-rtcamTalkMute` keeps the
// voice silent while every sentence still takes as long as it would to say.
// A file whose name contains "bargein" is pushed while an answer is being
// spoken, to exercise talking over it. Everything lands in
// Documents/talk-feed/log.jsonl.

#if DEBUG
enum TalkFeedTest {
    static var active: Bool { ProcessInfo.processInfo.arguments.contains("-rtcamTalkFeed") }
    static var mute: Bool { ProcessInfo.processInfo.arguments.contains("-rtcamTalkMute") }
    static let started = Date()

    static var folder: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("talk-feed", isDirectory: true)
    }

    private static let lock = NSLock()

    static func log(_ obj: [String: Any]) {
        guard active, let dir = folder else { return }
        var o = obj
        o["t"] = (Date().timeIntervalSince(started) * 1000).rounded() / 1000
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        let url = dir.appendingPathComponent("log.jsonl")
        let bytes = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(bytes); try? h.close()
        } else {
            try? bytes.write(to: url)
        }
    }
}

extension TalkController {
    func testLog(_ obj: [String: Any]) { TalkFeedTest.log(obj) }

    func configureTestFeed() {
        guard TalkFeedTest.active, let dir = TalkFeedTest.folder else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("log.jsonl"))
        listener.feedMode = true
        voice.muted = TalkFeedTest.mute
        voice.onSentence = { text in TalkFeedTest.log(["event": "say", "text": text]) }
        TalkFeedTest.log(["event": "start", "muted": TalkFeedTest.mute,
                          "level": ModelPicker.level(for: .scene).rawValue])
    }

    /// The feeder: a steady real-time stream, silence unless a question is
    /// due. Each question waits until the app is listening; a barge-in clip
    /// waits until an answer is being spoken.
    func startTestFeed() {
        guard TalkFeedTest.active, let dir = TalkFeedTest.folder else { return }
        let clips = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let first = clips.first, let probe = try? AVAudioFile(forReading: first) else {
            TalkFeedTest.log(["event": "no clips"]); return
        }
        let format = probe.processingFormat
        let frames: AVAudioFrameCount = 1024
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        silence.frameLength = frames // zeroed
        TalkFeedTest.log(["event": "clips", "names": clips.map(\.lastPathComponent), "rate": format.sampleRate])

        let clock = FeedClock(rate: format.sampleRate)
        Task { @MainActor in
            func push(_ b: AVAudioPCMBuffer) async { await self.feedPush(b, clock: clock) }
            func silenceUntil(timeout: TimeInterval, _ ready: () -> Bool) async -> Bool {
                let until = Date().addingTimeInterval(timeout)
                while Date() < until {
                    if ready() { return true }
                    await push(silence)
                }
                return false
            }
            for clip in clips {
                guard self.running else { return }
                let bargeIn = clip.lastPathComponent.contains("bargein")
                let ok: Bool
                if bargeIn {
                    // Into the middle of an answer that is being spoken.
                    ok = await silenceUntil(timeout: 90) { self.phase == .answering && self.voice.isBusy }
                    if ok { _ = await silenceUntil(timeout: 0.8) { false } }
                } else {
                    ok = await silenceUntil(timeout: 120) { self.phase == .listening && self.listener.isListening }
                    // A beat after the mic opens, like a person would leave.
                    if ok { _ = await silenceUntil(timeout: 0.6) { false } }
                }
                guard ok, let file = try? AVAudioFile(forReading: clip) else {
                    TalkFeedTest.log(["event": "clip skipped", "clip": clip.lastPathComponent, "phase": self.phase.words])
                    continue
                }
                TalkFeedTest.log(["event": "clip start", "clip": clip.lastPathComponent, "phase": self.phase.words])
                while file.framePosition < file.length {
                    guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                          (try? file.read(into: b, frameCount: frames)) != nil, b.frameLength > 0 else { break }
                    await push(b)
                }
                TalkFeedTest.log(["event": "speech end", "clip": clip.lastPathComponent,
                                  "at": Date().timeIntervalSince1970])
            }
            // Let the last answer finish, then end Talk.
            _ = await silenceUntil(timeout: 90) { self.phase == .listening && self.listener.isListening }
            _ = await silenceUntil(timeout: 2) { false }
            TalkFeedTest.log(["event": "done"])
            self.end()
        }
    }
}
extension TalkController {
    /// One buffer into the listener, paced to real time.
    fileprivate func feedPush(_ b: AVAudioPCMBuffer, clock: FeedClock) async {
        clock.pushed += Double(b.frameLength) / clock.rate
        let wait = clock.start.addingTimeInterval(clock.pushed).timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        listener.inject(b)
    }
}

fileprivate final class FeedClock {
    let start = Date()
    let rate: Double
    var pushed = 0.0
    init(rate: Double) { self.rate = rate }
}
#else
extension TalkController {
    func testLog(_: [String: Any]) {}
    func configureTestFeed() {}
    func startTestFeed() {}
}
#endif
