import Foundation
import UIKit

/// Talk mode timing test, started only by the launch argument `-rtcamTalkTest`
/// (devicectl or Xcode; nobody can reach it from the app). It runs Talk's own
/// answer path (routing, the detector context, memory, streamed answer) on
/// the bundled speed-check photo, or on every .jpg in Documents/talk-test,
/// without the mic or the voice, and writes one JSON line per question to
/// Documents/talk-test/results.jsonl: when the first whole sentence was ready
/// to speak, the total, the level and the answer. Nothing leaves the phone.
@available(iOS 17.0, *)
enum TalkSelfTest {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-rtcamTalkTest") }

    static let questions = [
        "What's this?",
        "What colour is it?",
        "What about the thing on the left?",
        "Is there anyone here?",
        "What's in front of me?",
    ]

    static func run() async {
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        defer { Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false } }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("talk-test", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("results.jsonl")
        try? fm.removeItem(at: out)
        var photos = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if photos.isEmpty, let bundled = Bundle.main.url(forResource: "SpeedCheckPhoto", withExtension: "jpg") {
            photos = [bundled]
        }
        write(["event": "start", "photos": photos.count, "level": ModelPicker.level(for: .scene).rawValue], to: out)
        let warmStart = Date()
        await OnDeviceVisionNarrator.shared.warmUp(for: .scene)
        write(["event": "warm", "seconds": round2(Date().timeIntervalSince(warmStart))], to: out)
        // A pretend detector list, so the context is the size it is in real use.
        let seen = [TalkSeen(name: "Chair", box: CGRect(x: 0.05, y: 0.5, width: 0.2, height: 0.3)),
                    TalkSeen(name: "Table", box: CGRect(x: 0.35, y: 0.55, width: 0.3, height: 0.3))]
        let memory = TalkMemory()
        for url in photos {
            guard let photo = UIImage(contentsOfFile: url.path) else { continue }
            for q in questions {
                let isPage = TalkRouting.asksAboutPage(q)
                let context = TalkPrompt.userText(question: q, seen: seen, newThings: [], caption: nil,
                                                  history: memory.recent())
                let box = TalkStreamBox()
                let started = Date()
                let firstAt = FirstSentenceClock()
                let reply = await OnDeviceVisionNarrator.shared.talk(context, about: photo,
                                                                    kind: isPage ? .page : .scene) { text in
                    if !box.feed(text).isEmpty { firstAt.mark() }
                    return true
                }
                let total = Date().timeIntervalSince(started)
                let tail = box.feed(box.lastText, final: true)
                if !tail.isEmpty { firstAt.mark() }
                let said = box.spoken.isEmpty ? (reply?.text ?? "") : box.spoken.joined(separator: " ")
                memory.note(question: q, answer: said)
                write(["image": url.lastPathComponent, "question": q,
                       "first_sentence": round2(firstAt.seconds(since: started) ?? total),
                       "first_token": round2(reply?.firstTokenSeconds ?? 0),
                       "total": round2(total), "level": reply?.level.rawValue ?? "none",
                       "answer": said], to: out)
            }
        }
        write(["event": "done"], to: out)
    }

    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    private static func write(_ obj: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// The moment the first whole sentence was ready, set once from any thread.
private final class FirstSentenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var at: Date?
    func mark() { lock.lock(); if at == nil { at = Date() }; lock.unlock() }
    func seconds(since start: Date) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return at.map { $0.timeIntervalSince(start) }
    }
}
