// Live Cam's voice: RT Cam's own voice, not Moonstone's. The person's chosen voice from Settings
// (SpeechManager.selectedVoiceIdentifier), RT Cam's text clean-up (SpeakableText), Your language
// (each sentence of content put into it before it is said, with the best installed voice for that language; the
// app's own lines come already in the app language, AppLang, and are said in a voice for it), and
// "Let VoiceOver do the talking" (with that setting off and VoiceOver running, every sentence goes to
// VoiceOver as an announcement and the app's own voice stays silent, so the two never talk over each other).
//
// The seam: LiveCallController only talks to `LiveVoiceOutput`. Moonstone speaks with Kokoro (af_heart);
// RT Cam hasn't chosen Apple vs Kokoro yet, so only the Apple voice is here. A Kokoro voice is one more
// type that conforms, nothing else changes.
import AVFoundation
import UIKit

@MainActor
protocol LiveVoiceOutput: AnyObject {
    /// Queue one English sentence of content (a model answer, something it saw). It is put into Your language,
    /// said in order, and `onStart` fires as it starts.
    func say(_ english: String)
    /// Queue one of the app's own lines, already in the app language (`text`, said with a voice for `lang`, never
    /// translated). `english` is its English key, which the call's logic compares (acks, check-ins, echoes).
    func sayLine(_ text: String, lang: String, english: String)
    func stop()
    var isBusy: Bool { get }
    /// Test aid: the queue and its timing run with no sound.
    var muted: Bool { get set }
    /// (what is said or shown, the English it came from, the language it is said in)
    var onStart: ((String, String, String) -> Void)? { get set }
    var onQuiet: (() -> Void)? { get set }
}

extension LiveVoiceOutput {
    /// The app's own fixed line, in the app language (Spanish when the app is Spanish).
    func sayOwn(_ english: String) { sayLine(L(english), lang: AppLang.code, english: english) }
}

@MainActor
final class LiveAppleVoice: NSObject, LiveVoiceOutput, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    var muted = false
    var onStart: ((String, String, String) -> Void)?
    var onQuiet: (() -> Void)?

    /// One queued sentence; `ready` puts it into Your language (instant in English).
    private struct Item {
        let english: String
        let ready: Task<(text: String, lang: String), Never>
    }
    private var queue: [Item] = []
    private var playing = false
    private var current: AVSpeechUtterance?
    private var silentUntil = Date.distantPast
    private var announcementUntil = Date.distantPast
    private var quietCheck: Task<Void, Never>?
    /// Bumped by stop(): anything started before it is thrown away.
    private var generation = 0

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
        NotificationCenter.default.addObserver(self, selector: #selector(announcementFinished),
                                               name: UIAccessibility.announcementDidFinishNotification, object: nil)
    }

    /// RT Cam's "Let VoiceOver do the talking": the setting off and VoiceOver on.
    static var usesVoiceOver: Bool {
        let speaksAloud = UserDefaults.standard.object(forKey: "speakAnswersAloud") as? Bool ?? true
        return !speaksAloud && UIAccessibility.isVoiceOverRunning
    }

    var isBusy: Bool { !queue.isEmpty || playing || synth.isSpeaking || Date() < silentUntil || Date() < announcementUntil }

    /// Moonstone 11/2 (Matt): Apple's voice read "Live camera" as "liv". "Live" before a noun or after go/is/went
    /// is pinned to "lyve"; "I live in Trinidad" is left alone. English, and Spanish lines that name Live Cam.
    static func pronounced(_ t: String) -> NSAttributedString {
        let a = NSMutableAttributedString(string: t)
        let ns = t as NSString
        let pats = [#"\blive(?=[\s-]+(camera|cam|video|stream|streaming|feed|view|mode|call|demo|chat|session|show|music|event|update|updates|action|footage|version|site|page|preview|data|test|link|broadcast|audio|tv)\b)"#,
                    #"(?<=\b(go|goes|going|went|gone|is|are|was|were|be|been|now)\s)live\b(?!\s+(in|at|with|on|here|there|near|by|like|for|together|alone|off|out))"#]
        for p in pats {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                a.addAttribute(NSAttributedString.Key(AVSpeechSynthesisIPANotationAttribute), value: "ˈlaɪv", range: m.range)
            }
        }
        return a
    }

    func say(_ english: String) {
        let t = english.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let ready = Task { @MainActor () -> (text: String, lang: String) in
            guard YourLanguage.activeCode != YourLanguageRules.english else { return (t, YourLanguageRules.english) }
            return await YourLanguage.intoActive(t)
        }
        queue.append(Item(english: t, ready: ready))
        playNext()
    }

    func sayLine(_ text: String, lang: String, english: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let ready = Task { @MainActor () -> (text: String, lang: String) in (t, lang) }
        queue.append(Item(english: english.isEmpty ? t : english, ready: ready))
        playNext()
    }

    private func playNext() {
        guard !playing, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        playing = true
        let gen = generation
        Task { @MainActor in
            let out = await item.ready.value
            guard gen == self.generation else { return }
            self.speak(out.text, lang: out.lang, english: item.english)
        }
    }

    private func speak(_ raw: String, lang: String, english: String) {
        let line = SpeakableText.spoken(raw, lang: lang)
        guard !line.isEmpty else { sentenceDone(); return }
        #if DEBUG
        SpeakLog.note("liveCam[\(lang)]", line)
        #endif
        onStart?(line, english, lang)
        if muted {
            // Same length as speaking it (about 2.6 words a second), no sound.
            silentUntil = Date().addingTimeInterval(0.35 + Double(line.split(separator: " ").count) / 2.6)
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + silentUntil.timeIntervalSinceNow) { [weak self] in
                guard let self, gen == self.generation else { return }
                self.sentenceDone()
            }
            return
        }
        if Self.usesVoiceOver {
            // VoiceOver reads it in the person's own voice and rate. If VoiceOver drops it, it never reports
            // back, so allow about the time it takes to say it.
            announcementUntil = Date().addingTimeInterval(max(2.5, Double(line.count) * 0.08))
            UIAccessibility.post(notification: .announcement, argument: SpeechManager.voiceOverLine(line, lang: lang))
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + announcementUntil.timeIntervalSinceNow) { [weak self] in
                guard let self, gen == self.generation, self.announcementUntil != .distantPast else { return }
                self.announcementUntil = .distantPast
                self.sentenceDone()
            }
            return
        }
        let prepared = YourLanguageVoice.prepare(line, lang: lang, selected: SpeechManager.shared.selectedVoiceIdentifier)
        // Spanish lines say "Live Cam" too (the name stays English), so they get the same "lyve".
        let u = lang == YourLanguageRules.english || lang == AppLang.spanish
            ? AVSpeechUtterance(attributedString: Self.pronounced(prepared.text))
            : AVSpeechUtterance(string: prepared.text)
        u.voice = prepared.voice ?? AVSpeechSynthesisVoice(language: "en-US")
        u.rate = 0.5   // RT Cam's rate everywhere (SpeechManager)
        current = u
        synth.speak(u)
    }

    @objc private func announcementFinished() {
        guard announcementUntil != .distantPast else { return }
        announcementUntil = .distantPast
        sentenceDone()
    }

    private func sentenceDone() {
        current = nil
        playing = false
        playNext()
        scheduleQuietCheck()
    }

    func stop() {
        quietCheck?.cancel()
        generation += 1
        for item in queue { item.ready.cancel() }
        queue.removeAll()
        current = nil
        playing = false
        silentUntil = .distantPast
        announcementUntil = .distantPast
        synth.stopSpeaking(at: .immediate)
    }

    private func scheduleQuietCheck() {
        quietCheck?.cancel()
        quietCheck = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                if !self.isBusy { self.onQuiet?(); return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in
            guard let cur = self.current, ObjectIdentifier(cur) == id else { return }
            self.sentenceDone()
        }
    }
    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        // stop() already cleared the queue.
    }
}
