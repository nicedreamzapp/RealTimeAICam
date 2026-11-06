@testable import RealTime_Ai_Cam
import Foundation
import Testing

/// Live Cam in Spanish (2026-11-05): the app's own lines are said in the app language with a voice for it, content
/// keeps Your language, and every line reached through a constant has its Spanish in the catalog.
@MainActor
@Suite(.serialized)
struct LiveCamSpanishTests {
    /// Records what reaches the voice and in which language.
    final class RecordingVoice: LiveVoiceOutput {
        var muted = true
        var onStart: ((String, String, String) -> Void)?
        var onQuiet: (() -> Void)?
        var lines: [(text: String, lang: String, english: String)] = []
        var content: [String] = []
        var isBusy: Bool { false }
        func say(_ english: String) { content.append(english) }
        func sayLine(_ text: String, lang: String, english: String) { lines.append((text, lang, english)) }
        func stop() {}
    }

    private func forcing(_ code: String, _ body: () -> Void) {
        UserDefaults.standard.set(code, forKey: AppLang.forcedKey)
        defer { UserDefaults.standard.removeObject(forKey: AppLang.forcedKey) }
        body()
    }

    @Test func everyIndirectLineHasSpanish() {
        let missing = LiveCamWords.indirectKeys.filter { !AppLang.hasSpanish($0) }
        #expect(missing.isEmpty, "no Spanish for: \(missing)")
    }

    @Test func formatLinesKeepTheirPlaceholder() {
        for k in LiveCamWords.indirectKeys where k.contains("%@") {
            #expect(AppLang.text(k, in: AppLang.spanish).contains("%@"), "\(k)")
        }
    }

    @Test func ownLineIsSpanishInASpanishVoice() {
        forcing("es") {
            let v = RecordingVoice()
            v.sayOwn(LiveCamWords.sayAgain)
            #expect(v.lines.count == 1)
            #expect(v.lines[0].lang == "es")
            #expect(v.lines[0].text == AppLang.text(LiveCamWords.sayAgain, in: "es"))
            #expect(v.lines[0].text != LiveCamWords.sayAgain)
            #expect(v.lines[0].english == LiveCamWords.sayAgain)   // the logic still compares the English key
            #expect(v.content.isEmpty)
        }
    }

    @Test func ownLineIsEnglishInEnglish() {
        forcing("en") {
            let v = RecordingVoice()
            v.sayOwn(LiveWords.firstGreeting)
            #expect(v.lines.first?.text == LiveWords.firstGreeting)
            #expect(v.lines.first?.lang == "en")
        }
    }

    @Test func aLineWithContentIsTranslatedWholeOnlyWhenYourLanguageIsTheAppLanguage() {
        #expect(LiveLine.translatesWhole(appCode: "es", yourCode: "es"))
        #expect(!LiveLine.translatesWhole(appCode: "es", yourCode: "en"))   // translator not ready: the Spanish line
        #expect(!LiveLine.translatesWhole(appCode: "en", yourCode: "en"))
        #expect(!LiveLine.translatesWhole(appCode: "en", yourCode: "fr"))   // app words stay English
    }

    @Test func spokenModeWordsStillSwitchAfterTranslation() {
        // "modo divertido" / "modo entrenador" / "modo análisis" put into English.
        #expect(LiveWords.modeSwitch("fun mode") == .funny)
        #expect(LiveWords.modeSwitch("trainer mode") == .coach)
        #expect(LiveWords.modeSwitch("analysis mode") == .analyze)
        #expect(LiveWords.modeSwitch("normal mode") == .normal)
    }

    @Test func newThingLineMatchesItsFormat() {
        #expect(String(format: LiveCamWords.newThing, LiveWords.newThings(["boat"])) == LiveWords.newThingLine(["boat"]))
    }
}
