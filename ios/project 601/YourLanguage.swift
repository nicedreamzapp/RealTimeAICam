import AVFoundation
import Combine
import Foundation
import Speech
import SwiftUI
import UIKit
#if canImport(Translation)
import Translation
#endif

/// "Your language" (2026-11-04, Play reviews from a French and a Spanish speaker:
/// everything was spoken in English). The language the person wants to HEAR. Read,
/// Object Detection, Help Me Aim and What's this? translate what they say into it
/// with Apple's on-device translator (iOS 18+; older phones stay English). Screens
/// and buttons stay English for now.
///
/// Matt's rule: no added MB and nothing downloads until the person clearly wants it.
/// The language downloads only on a tap of "Download <Name> once, then it works
/// offline"; until then everything works exactly as in English. English = no change
/// at all. Same rules and words as Android YourLanguage.kt.
enum YourLanguageRules {
    static let english = "en"

    /// English plus the 17 languages Read can read.
    static let languages: [(code: String, name: String)] =
        [(english, "English")] + TranslateLanguage.all.map { ($0.code, $0.name) }

    static var codes: [String] { languages.map(\.code) }

    /// The language's name in the app's language: "Spanish" in English, "Español" in Spanish.
    static func name(_ code: String, in ui: String = AppLang.code) -> String {
        let englishName = languages.first { $0.code == code }?.name ?? "English"
        guard ui != english, let local = Locale(identifier: ui).localizedString(forIdentifier: code)
        else { return englishName }
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    /// The name inside a sentence: Spanish writes language names in lowercase ("en español").
    static func nameInSentence(_ code: String) -> String {
        AppLang.isSpanish ? name(code).lowercased(with: AppLang.locale) : name(code)
    }

    /// A phone language ("es-MX", "zh-Hans-CN", "pt-BR", "in") to one of our codes, or nil.
    static func normalize(_ phoneLanguage: String) -> String? {
        let lower = phoneLanguage.lowercased().replacingOccurrences(of: "_", with: "-")
        let base = lower.components(separatedBy: "-").first ?? lower
        switch base {
        case "zh":
            // Traditional Chinese isn't one of Read's languages.
            let traditional = lower.contains("hant") || lower.hasSuffix("-tw") || lower.hasSuffix("-hk") || lower.hasSuffix("-mo")
            return traditional ? nil : "zh-Hans"
        case "in": return codes.contains("id") ? "id" : nil
        default: return codes.contains(base) ? base : nil
        }
    }

    /// The phone's language when the app can translate into it, else English.
    /// Apple's translator is iOS 18+: older phones are always English.
    static func defaultFor(_ phoneLanguage: String, translatorAvailable: Bool = true) -> String {
        guard translatorAvailable else { return english }
        return normalize(phoneLanguage) ?? english
    }

    /// A saved choice wins; nothing saved follows the phone.
    static func resolve(saved: String?, phoneLanguage: String, translatorAvailable: Bool = true) -> String {
        guard translatorAvailable else { return english }
        if let saved, codes.contains(saved) { return saved }
        return defaultFor(phoneLanguage)
    }

    /// Announce once on first launch: only when the phone is in a supported language other than English.
    static func shouldAnnounceFirstLaunch(phoneLanguage: String, alreadyAnnounced: Bool, translatorAvailable: Bool = true) -> Bool {
        !alreadyAnnounced && defaultFor(phoneLanguage, translatorAvailable: translatorAvailable) != english
    }

    static func firstLaunchLine(_ code: String) -> String {
        let n = nameInSentence(code)
        return L("Your language is %@. Spoken results can be translated into %@ after a one-time download. You can change this in Settings.", n, n)
    }

    static func downloadRow(_ code: String) -> String { L("Download %@ once, then it works offline", nameInSentence(code)) }
    static func downloadingLine(_ code: String) -> String { L("Downloading %@, one time only.", nameInSentence(code)) }
    static func stillDownloadingLine(_ code: String) -> String { L("Still downloading %@.", nameInSentence(code)) }
    static func readyLine(_ code: String) -> String { L("%@ is ready, it works offline now.", name(code)) }
    static func failedLine(_ code: String) -> String {
        L("%@ didn't download. Connect to the internet, then tap the download button again.", name(code))
    }
    /// Apple's download window (seen on an iPhone 12, 2026-11-05): a "Translate" sheet over the
    /// lower half of the screen, "Required Downloads", one line per language, each with a round
    /// download button at its right end (VoiceOver: "Arrow Down Circle"). One tap downloads them
    /// all; the window stays open while it downloads and closes by itself when done.
    static func sheetOpenedLine(_ code: String) -> String {
        L("Apple opened a window to download %@, in the lower half of the screen. Tap the round button with a down arrow on the right, next to the language names.", nameInSentence(code))
    }
    static func sheetWaitingLine(_ code: String) -> String {
        L("The %@ download is waiting for your tap: the round button with a down arrow on the right, in the lower half of the screen. If you already tapped it, it is downloading and the window closes by itself when it's done.", nameInSentence(code))
    }
    static func sheetClosedLine(_ code: String) -> String {
        L("Apple's download window closed before %@ downloaded. Check the internet connection, then tap Download %@ again in Settings, under Your language.", nameInSentence(code), nameInSentence(code))
    }
    /// Read by the English voice when no voice for `code` is installed, so it stays English
    /// out loud; `noVoiceShown` is the same line for the screen in the app's language.
    static func noVoiceLine(_ code: String) -> String {
        "No \(name(code, in: english)) voice is installed on this phone. You can add one in the phone's settings, under Accessibility, Spoken Content, Voices."
    }
    static func noVoiceShown(_ code: String) -> String {
        L("No %@ voice is installed on this phone. You can add one in the phone's settings, under Accessibility, Spoken Content, Voices.", nameInSentence(code))
    }

    /// The Read pill. `page` is the page's language code (nil = English page). With
    /// Your language English nothing changes ("English", "Span → Eng", "French → Eng").
    /// Otherwise it names both ends: "French → Spanish", "English → Spanish", or just
    /// "Spanish" when they match.
    static func pillLabel(page: String?, target: String) -> String {
        if target == english {
            guard let page, page != english else { return name(english) }
            if AppLang.isSpanish { return L("%@ → Eng", name(page)) }
            return page == "es" ? "Span → Eng" : "\(name(page)) → Eng"
        }
        let from = name(page ?? english)
        let to = name(target)
        return from == to ? to : "\(from) → \(to)"
    }

    /// What VoiceOver hears for the pill.
    static func pillSpoken(page: String?, target: String) -> String {
        let from = name(page ?? english)
        let to = name(target)
        if target == english { return page == nil || page == english ? name(english) : L("%@, translated to %@", from, nameInSentence(english)) }
        return from == to ? to : L("%@, translated to %@", from, nameInSentence(target))
    }

    /// One short paragraph, same words in the INFO GUIDE and the spoken tutorial (and on Android).
    static var guide: String {
        L("Your language: in Settings, pick the language you want to hear. The first time, tap Download once; after that it works offline. Read, Object Detection, Help Me Aim and What's this? then speak in your language. Buttons, menus and this guide are in Spanish when your phone or Your language is Spanish, and in English otherwise.")
    }
}

/// What's this? in Your language. The vision model reads and writes English, so its
/// answer is translated before it is shown and said, and a follow-up asked in Your
/// language is put into English for the model. When translation can't happen (no
/// pack, an error) the English stands, exactly as before. Same as Android AnswerLanguage.kt.
enum AnswerLanguage {
    typealias Translate = (_ text: String, _ from: String, _ to: String) async -> String?

    static func forPerson(_ english: String, lang: String, translate: Translate) async -> (text: String, lang: String) {
        guard lang != YourLanguageRules.english, !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (english, YourLanguageRules.english)
        }
        guard let out = await translate(english, YourLanguageRules.english, lang),
              !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return (english, YourLanguageRules.english) }
        return (out, lang)
    }

    static func questionForModel(_ question: String, lang: String, translate: Translate) async -> String {
        guard lang != YourLanguageRules.english, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return question }
        if let out = await translate(question, lang, YourLanguageRules.english),
           !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return out }
        return question
    }
}

// MARK: - The setting

@MainActor
final class YourLanguage: ObservableObject {
    static let shared = YourLanguage()

    static let key = "userLanguage"
    static let announcedKey = "userLanguageAnnounced"

    /// The chosen language (may still need its download).
    @Published private(set) var code: String
    /// Languages whose translation is on the phone (English always is).
    @Published private(set) var readyCodes: Set<String> = [YourLanguageRules.english]
    /// The language downloading right now.
    @Published private(set) var downloading: String?

    /// Apple's translator is iOS 18+.
    nonisolated static var translatorAvailable: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    nonisolated static var phoneLanguage: String { Locale.preferredLanguages.first ?? "en" }

    private init() {
        code = YourLanguageRules.resolve(saved: UserDefaults.standard.string(forKey: Self.key),
                                         phoneLanguage: Self.phoneLanguage,
                                         translatorAvailable: Self.translatorAvailable)
        Self.setSnapshot(YourLanguageRules.english)
    }

    func isReady(_ c: String) -> Bool { c == YourLanguageRules.english || readyCodes.contains(c) }

    /// Your language when its translation is on the phone, else English (today's behaviour).
    var active: String { isReady(code) ? code : YourLanguageRules.english }

    /// Thread-safe copy of `active` for the camera and speech queues.
    private nonisolated(unsafe) static var snapshot = YourLanguageRules.english
    private static let snapshotLock = NSLock()
    nonisolated static var activeCode: String {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return snapshot
    }

    private nonisolated static func setSnapshot(_ c: String) {
        snapshotLock.lock(); snapshot = c; snapshotLock.unlock()
    }

    private func publish() {
        Self.setSnapshot(active)
        if active != YourLanguageRules.english { ObjectLabelCache.shared.prepare(active) }
    }

    func set(_ new: String) {
        guard YourLanguageRules.codes.contains(new) else { return }
        UserDefaults.standard.set(new, forKey: Self.key)
        code = new
        publish()
        Task { await refresh() }
        NSLog("YourLanguage: set %@", new)
    }

    /// Ask Apple whether the chosen language is on the phone. Asking never downloads.
    func refresh() async {
        let c = code
        guard c != YourLanguageRules.english else { publish(); return }
        if await YourLanguageTranslator.isInstalled(c) { readyCodes.insert(c) } else { readyCodes.remove(c) }
        publish()
        NSLog("YourLanguage: %@ installed=%d", c, readyCodes.contains(c) ? 1 : 0)
    }

    /// The person tapped the download row. The ONLY place Your language downloads.
    /// `say` gets the spoken progress lines.
    func download(say: @escaping (String) -> Void) {
        let c = code
        guard c != YourLanguageRules.english, !isReady(c), downloading == nil else { return }
        downloading = c
        NSLog("YourLanguage: download requested by tap: %@", c)
        say(YourLanguageRules.downloadingLine(c))
        let baseline = DownloadSheetWatch.stack().depth
        let state = DownloadGuideState(DownloadGuide(start: ProcessInfo.processInfo.systemUptime))
        // Watches for Apple's download window and says where its button is (DownloadGuide).
        let progress = Task { @MainActor [weak self] in
            var lastTop = ""
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !state.done, self?.downloading == c else { return }
                let now = DownloadSheetWatch.stack()
                if now.top != lastTop {
                    lastTop = now.top
                    NSLog("YourLanguage: over the app now: %@ (depth %d, was %d)", now.top, now.depth, baseline)
                }
                if let line = state.guide.tick(sheetShowing: now.depth > baseline, now: ProcessInfo.processInfo.systemUptime) {
                    say(DownloadGuide.text(line, code: c))
                }
            }
        }
        Task { @MainActor in
            let ok = await YourLanguageTranslator.shared.prepare(to: c)
            state.done = true
            progress.cancel()
            downloading = nil
            if ok { readyCodes.insert(c) }
            publish()
            NSLog("YourLanguage: download %@ ok=%d", c, ok ? 1 : 0)
            say(DownloadGuide.text(state.guide.finished(ok: ok), code: c))
        }
    }

    /// Once, on the first launch, when the phone is in a supported language other than English.
    func firstLaunchLineIfDue() -> String? {
        let d = UserDefaults.standard
        guard YourLanguageRules.shouldAnnounceFirstLaunch(phoneLanguage: Self.phoneLanguage,
                                                          alreadyAnnounced: d.bool(forKey: Self.announcedKey),
                                                          translatorAvailable: Self.translatorAvailable)
        else { return nil }
        d.set(true, forKey: Self.announcedKey)
        return YourLanguageRules.firstLaunchLine(code)
    }

    // MARK: Translating

    /// Translate one piece of text. Never downloads: returns nil when either side
    /// isn't on the phone or on any error, so the caller keeps the original.
    nonisolated static func translate(_ text: String, from: String, to: String) async -> String? {
        if from == to { return text }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return await YourLanguageTranslator.shared.translate(text, from: from, to: to)
    }

    /// English into Your language (or the English back unchanged when it's English / can't).
    nonisolated static func intoActive(_ english: String) async -> (text: String, lang: String) {
        await AnswerLanguage.forPerson(english, lang: activeCode, translate: translate)
    }

    /// Typed or spoken in Your language, put into English for the app's own English logic.
    nonisolated static func toEnglish(_ text: String) async -> String {
        await AnswerLanguage.questionForModel(text, lang: activeCode, translate: translate)
    }
}

// MARK: - Apple's translator, usable from anywhere

/// Apple's TranslationSession only comes from a SwiftUI view on iOS 18–25, so one
/// invisible host view at the root of the app (`.yourLanguageHost()`) serves every
/// request: Object Detection names, Help Me Aim lines, What's this? answers.
@MainActor
final class YourLanguageTranslator: ObservableObject {
    static let shared = YourLanguageTranslator()

    struct Job {
        let id = UUID()
        let text: String
        let from: String
        let to: String
        let prepare: Bool
        /// One of translateMany's names: served after any single line asked meanwhile.
        var batch = false
        let done: (String?) -> Void
    }

    private var jobs: [Job] = []
    private var serving = false
    private var servingPair: (String, String)?

    #if canImport(Translation)
    @Published var configurationBox: AnyObject?
    #endif

    private let cache = NSCache<NSString, NSString>()

    // MARK: Test stub (DEBUG builds only)

    /// The Simulator can't download Apple's languages, so UI tests launch with
    /// -rtcamFakeTranslator: "downloads" take a moment and translations come from
    /// a small phrase list ("[es] text" for anything else). Never in release builds.
    nonisolated static var isFake: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-rtcamFakeTranslator")
        #else
        return false
        #endif
    }

    private static let fakePacksKey = "fakeTranslatorPacks"

    nonisolated static func fakeTranslate(_ text: String, from: String, to: String) -> String {
        let phrases: [String: [String: String]] = [
            "es": ["exit": "Salida", "hello world": "Hola mundo", "open daily": "Abierto todos los días",
                   "a white coffee mug on a wooden table.": "Una taza de café blanca sobre una mesa de madera.",
                   "chair": "silla", "dog": "perro", "person": "persona", "computer mouse": "ratón de ordenador",
                   "mouse (animal)": "ratón (animal)", "eyeglasses": "anteojos", "coffee cup": "taza de café",
                   "move left.": "Muévete a la izquierda.", "the cup is white.": "La taza es blanca."],
            "fr": ["exit": "Sortie", "hello world": "Bonjour le monde", "open daily": "Ouvert tous les jours",
                   "chair": "chaise", "dog": "chien", "person": "personne", "computer mouse": "souris d'ordinateur",
                   "mouse (animal)": "souris (animal)", "eyeglasses": "lunettes"],
            "en": ["taza": "cup", "una taza": "a cup", "¿de qué color es la taza?": "What color is the cup?",
                   "de que color es la taza": "What color is the cup?",
                   "tasse": "cup", "salida": "exit", "sortie": "exit"],
        ]
        let key = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let hit = phrases[to]?[key] { return hit }
        return "[\(to)] \(text)"
    }

    nonisolated static func isInstalled(_ code: String) async -> Bool {
        if isFake { return Set(UserDefaults.standard.stringArray(forKey: fakePacksKey) ?? []).contains(code) }
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: YourLanguageRules.english),
                to: Locale.Language(identifier: code))
            return status == .installed
        }
        #endif
        return false
    }

    // MARK: Requests

    /// How long a queued translation may wait: 20 s for one line, more for each name in a
    /// translateMany list, since the list is served one name after another.
    nonisolated static func batchTimeout(_ count: Int) -> TimeInterval { 20 + Double(count) * 0.25 }

    func translate(_ text: String, from: String, to: String) async -> String? {
        await translate(text, from: from, to: to, batchOf: 0)
    }

    private func translate(_ text: String, from: String, to: String, batchOf count: Int) async -> String? {
        let key = "\(from)>\(to)>\(text)" as NSString
        if let hit = cache.object(forKey: key) { return hit as String }
        guard YourLanguage.shared.isReady(from), YourLanguage.shared.isReady(to) else { return nil }
        if Self.isFake {
            let out = Self.fakeTranslate(text, from: from, to: to)
            cache.setObject(out as NSString, forKey: key)
            return out
        }
        let out: String? = await withCheckedContinuation { cont in
            // A real iPhone 12 serves about 25 names a second: all 620 queued at once with 20 s
            // each lost the last hundred, so the Spanish list never built (2026-11-05).
            var job = Job(text: text, from: from, to: to, prepare: false) { cont.resume(returning: $0) }
            job.batch = count > 0
            enqueue(job, timeout: Self.batchTimeout(count))
        }
        if let out { cache.setObject(out as NSString, forKey: key) }
        return out
    }

    /// Many at once (the Object Detection list): queued together so one session serves them all.
    func translateMany(_ texts: [String], from: String, to: String) async -> [String?] {
        await withTaskGroup(of: (Int, String?).self) { group in
            for (i, t) in texts.enumerated() {
                group.addTask { @MainActor in (i, await self.translate(t, from: from, to: to, batchOf: texts.count)) }
            }
            var out = [String?](repeating: nil, count: texts.count)
            for await (i, s) in group { out[i] = s }
            return out
        }
    }

    /// English → `code`: Apple's own download (its sheet asks once). Only from the download row.
    func prepare(to code: String) async -> Bool {
        if Self.isFake {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var packs = Set(UserDefaults.standard.stringArray(forKey: Self.fakePacksKey) ?? [])
            packs.insert(code)
            UserDefaults.standard.set(Array(packs), forKey: Self.fakePacksKey)
            return true
        }
        guard Self.translatorAvailable else { return false }
        let _: String? = await withCheckedContinuation { cont in
            enqueue(Job(text: "", from: YourLanguageRules.english, to: code, prepare: true) { cont.resume(returning: $0) },
                    timeout: 900)
        }
        return await Self.isInstalled(code)
    }

    nonisolated static var translatorAvailable: Bool { YourLanguage.translatorAvailable }

    private func enqueue(_ job: Job, timeout: TimeInterval) {
        guard Self.translatorAvailable else { job.done(nil); return }
        // A single line (Read, a cue, Help Me Aim's word) goes ahead of a waiting name list.
        if !job.batch, let firstBatch = jobs.firstIndex(where: { $0.batch }) {
            jobs.insert(job, at: firstBatch)
        } else {
            jobs.append(job)
        }
        let id = job.id
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, let i = jobs.firstIndex(where: { $0.id == id }) else { return }
            let stale = jobs.remove(at: i)
            NSLog("YourLanguage: translation timed out (%@ > %@)", stale.from, stale.to)
            stale.done(nil)
        }
        pump()
    }

    private func pump() {
        guard !serving, let first = jobs.first else { return }
        serving = true
        servingPair = (first.from, first.to)
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            let source = Locale.Language(identifier: first.from)
            let target = Locale.Language(identifier: first.to)
            if let box = configurationBox as? ConfigBox, box.configuration?.source == source, box.configuration?.target == target {
                box.configuration?.invalidate()
                objectWillChange.send()
            } else {
                configurationBox = ConfigBox(TranslationSession.Configuration(source: source, target: target))
            }
            return
        }
        #endif
        serving = false
    }

    #if canImport(Translation)
    @available(iOS 18.0, *)
    final class ConfigBox {
        var configuration: TranslationSession.Configuration?
        init(_ c: TranslationSession.Configuration) { configuration = c }
    }

    /// Called by the host view's translationTask with a live session.
    @available(iOS 18.0, *)
    func serve(_ session: TranslationSession) async {
        guard let (from, to) = servingPair else { serving = false; return }
        while let i = jobs.firstIndex(where: { $0.from == from && $0.to == to }) {
            let job = jobs.remove(at: i)
            if job.prepare {
                do {
                    try await session.prepareTranslation()
                    job.done("ok")
                } catch {
                    NSLog("YourLanguage: prepare failed %@", "\(error)")
                    job.done(nil)
                }
                continue
            }
            do {
                let r = try await session.translate(job.text)
                job.done(r.targetText)
            } catch {
                NSLog("YourLanguage: translate %@>%@ failed %@", from, to, "\(error)")
                job.done(nil)
            }
            // A single line for another pair (a spoken Spanish question) asked while the name
            // list runs: hand over now instead of after the whole list (review 2026-11-05).
            if job.batch, let next = jobs.first, !next.batch, next.from != from || next.to != to { break }
        }
        serving = false
        servingPair = nil
        pump()
    }
    #endif
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct YourLanguageHostModifier: ViewModifier {
    @ObservedObject var translator = YourLanguageTranslator.shared

    func body(content: Content) -> some View {
        let config = (translator.configurationBox as? YourLanguageTranslator.ConfigBox)?.configuration
        content.translationTask(config) { session in
            await translator.serve(session)
        }
    }
}
#endif

extension View {
    /// Put once at the root of the app: serves Your language translations.
    @ViewBuilder
    func yourLanguageHost() -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            modifier(YourLanguageHostModifier())
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - Voices and listening

enum YourLanguageVoice {
    /// The prefix AVSpeechSynthesisVoice uses for one of our codes.
    static func voicePrefix(_ code: String) -> String { code == "zh-Hans" ? "zh-CN" : code }

    /// The best installed voice for a language: the phone's own region first, then quality.
    static func best(for code: String) -> AVSpeechSynthesisVoice? {
        let prefix = voicePrefix(code)
        let all = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == prefix || $0.language.hasPrefix(prefix + "-") || $0.language.hasPrefix(prefix)
        }
        guard !all.isEmpty else { return nil }
        let region = Locale.current.region?.identifier ?? ""
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = 0
            if v.language.hasSuffix("-" + region) { s += 10 }
            switch v.quality {
            case .premium: s += 6
            case .enhanced: s += 4
            default: s += 0
            }
            if v.voiceTraits.contains(.isNoveltyVoice) { s -= 20 }
            return s
        }
        return all.max { score($0) < score($1) }
    }

    /// True when `voice` is a voice for language `code` ("es" matches es-MX, es-ES, ...).
    static func speaks(_ voice: AVSpeechSynthesisVoice, _ code: String) -> Bool {
        let prefix = voicePrefix(code)
        return voice.language == prefix || voice.language.hasPrefix(prefix + "-")
    }

    /// Every installed voice for a language, alphabetical (the voice picker's list).
    static func all(for code: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { speaks($0, code) }.sorted { $0.name < $1.name }
    }

    private static var warned = Set<String>()
    private static let lock = NSLock()

    /// The voice for text in `lang`: the person's chosen voice for English, the best
    /// installed voice for anything else. With no voice for that language the text
    /// gets one English sentence in front saying so (once per launch), and the
    /// chosen voice reads it.
    static func prepare(_ text: String, lang: String, selected: String) -> (text: String, voice: AVSpeechSynthesisVoice?) {
        let picked = AVSpeechSynthesisVoice(identifier: selected)
        // The picked voice reads its own language only (the picker lists the app language's
        // voices, so a Spanish speaker may have picked a Spanish one): English text in a
        // Spanish voice, or the reverse, falls to the best voice for that language.
        if let v = voice(for: lang, selected: selected) { return (text, v) }
        // No voice for `lang`: an English voice says the English warning and the text (the
        // picked voice only if it is an English one).
        let chosen = voice(for: YourLanguageRules.english, selected: selected)
        lock.lock()
        let first = warned.insert(lang).inserted
        lock.unlock()
        NSLog("YourLanguage: no voice installed for %@", lang)
        return (first ? YourLanguageRules.noVoiceLine(lang) + " " + text : text, chosen)
    }

    /// The voice for text in `lang`, with no warning side effects: the picked voice when it
    /// speaks `lang`, else the best installed one (always one for English), else nil.
    static func voice(for lang: String, selected: String) -> AVSpeechSynthesisVoice? {
        if let picked = AVSpeechSynthesisVoice(identifier: selected), speaks(picked, lang) { return picked }
        if let v = best(for: lang) { return v }
        return lang == YourLanguageRules.english ? AVSpeechSynthesisVoice(language: "en-US") : nil
    }

    /// Speech recognition in Your language when the phone can do it offline, else English.
    static func recognizer() -> SFSpeechRecognizer? {
        let lang = YourLanguage.activeCode
        if lang != YourLanguageRules.english {
            let base = voicePrefix(lang)
            let preferred = Locale.preferredLanguages.first { $0.hasPrefix(base) } ?? base
            if let r = SFSpeechRecognizer(locale: Locale(identifier: preferred)), r.supportsOnDeviceRecognition { return r }
        }
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }
}
