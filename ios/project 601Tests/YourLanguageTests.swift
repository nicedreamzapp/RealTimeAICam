@testable import RealTime_Ai_Cam
import AVFoundation
import Foundation
import Testing

// Same cases as Android's YourLanguageTest.kt.
struct YourLanguageTests {
    @Test func eighteenChoicesEnglishFirst() {
        #expect(YourLanguageRules.codes.count == 18)
        #expect(YourLanguageRules.codes.first == "en")
        #expect(Set(YourLanguageRules.codes).count == 18)
        for c in ["es", "fr", "de", "it", "pt", "nl", "pl", "tr", "id", "vi", "ru", "uk", "zh-Hans", "ja", "ko", "th", "ar"] {
            #expect(YourLanguageRules.codes.contains(c), "missing \(c)")
        }
    }

    @Test func defaultFollowsThePhoneWhenSupported() {
        #expect(YourLanguageRules.defaultFor("es-MX") == "es")
        #expect(YourLanguageRules.defaultFor("fr-CA") == "fr")
        #expect(YourLanguageRules.defaultFor("pt-BR") == "pt")
        #expect(YourLanguageRules.defaultFor("zh-Hans-CN") == "zh-Hans")
        #expect(YourLanguageRules.defaultFor("zh-Hant-TW") == "en") // Traditional isn't a Read language
        #expect(YourLanguageRules.defaultFor("en-US") == "en")
        #expect(YourLanguageRules.defaultFor("sv-SE") == "en") // not supported: English
        #expect(YourLanguageRules.defaultFor("fr-FR", translatorAvailable: false) == "en") // iOS 17
    }

    @Test func savedChoiceWins() {
        #expect(YourLanguageRules.resolve(saved: "fr", phoneLanguage: "es-ES") == "fr")
        #expect(YourLanguageRules.resolve(saved: "en", phoneLanguage: "es-ES") == "en")
        #expect(YourLanguageRules.resolve(saved: nil, phoneLanguage: "es-ES") == "es")
        #expect(YourLanguageRules.resolve(saved: "xx", phoneLanguage: "de-DE") == "de")
        #expect(YourLanguageRules.resolve(saved: "fr", phoneLanguage: "es-ES", translatorAvailable: false) == "en")
    }

    @Test func firstLaunchAnnouncedOnlyForSupportedNonEnglishOnce() {
        #expect(YourLanguageRules.shouldAnnounceFirstLaunch(phoneLanguage: "fr-FR", alreadyAnnounced: false))
        #expect(!YourLanguageRules.shouldAnnounceFirstLaunch(phoneLanguage: "fr-FR", alreadyAnnounced: true))
        #expect(!YourLanguageRules.shouldAnnounceFirstLaunch(phoneLanguage: "en-GB", alreadyAnnounced: false))
        #expect(!YourLanguageRules.shouldAnnounceFirstLaunch(phoneLanguage: "sv-SE", alreadyAnnounced: false))
        #expect(YourLanguageRules.firstLaunchLine("fr").hasPrefix("Your language is French."))
    }

    @Test func downloadRowWording() {
        #expect(YourLanguageRules.downloadRow("es") == "Download Spanish once, then it works offline")
        #expect(YourLanguageRules.downloadingLine("fr") == "Downloading French, one time only.")
        #expect(YourLanguageRules.readyLine("es") == "Spanish is ready, it works offline now.")
    }

    @Test func pillUnchangedForEnglish() {
        #expect(YourLanguageRules.pillLabel(page: nil, target: "en") == "English")
        #expect(YourLanguageRules.pillLabel(page: "es", target: "en") == "Span → Eng")
        #expect(YourLanguageRules.pillLabel(page: "fr", target: "en") == "French → Eng")
        #expect(YourLanguageRules.pillSpoken(page: "fr", target: "en") == "French, translated to English")
    }

    @Test func pillNamesBothEndsForYourLanguage() {
        #expect(YourLanguageRules.pillLabel(page: "fr", target: "es") == "French → Spanish")
        #expect(YourLanguageRules.pillLabel(page: nil, target: "es") == "English → Spanish")
        #expect(YourLanguageRules.pillLabel(page: "en", target: "es") == "English → Spanish")
        #expect(YourLanguageRules.pillLabel(page: "es", target: "es") == "Spanish")
        #expect(YourLanguageRules.pillSpoken(page: nil, target: "fr") == "English, translated to French")
    }

    private static let fake: AnswerLanguage.Translate = { text, from, to in
        if to == "es", text == "A white mug." { return "Una taza blanca." }
        if from == "es", to == "en", text == "¿De qué color es?" { return "What color is it?" }
        return nil
    }

    @Test func answerTranslatedIntoYourLanguage() async {
        let r = await AnswerLanguage.forPerson("A white mug.", lang: "es", translate: Self.fake)
        #expect(r.text == "Una taza blanca." && r.lang == "es")
    }

    @Test func answerStaysEnglishForEnglishOrWhenTranslationFails() async {
        let en = await AnswerLanguage.forPerson("A white mug.", lang: "en", translate: Self.fake)
        #expect(en.text == "A white mug." && en.lang == "en")
        let failed = await AnswerLanguage.forPerson("Something else.", lang: "es", translate: Self.fake)
        #expect(failed.text == "Something else." && failed.lang == "en")
    }

    @Test func followUpQuestionGoesToTheModelInEnglish() async {
        #expect(await AnswerLanguage.questionForModel("¿De qué color es?", lang: "es", translate: Self.fake) == "What color is it?")
        #expect(await AnswerLanguage.questionForModel("What is it?", lang: "en", translate: Self.fake) == "What is it?")
        #expect(await AnswerLanguage.questionForModel("¿Qué?", lang: "es", translate: Self.fake) == "¿Qué?")
    }

    @Test func spanishTargetWordMapsToCup() async {
        let word = await AimLanguage.wordForMatching("taza", lang: "es") { text, from, to in
            (text == "taza" && from == "es" && to == "en") ? "a cup" : nil
        }
        #expect(word == "cup")
        let classes = AimObjectFinder.loadClassNames()
        if !classes.isEmpty {
            let match = AimVocabulary.match(word, classNames: classes)
            #expect(match != nil, "cup should match a Help Me Aim class")
        }
    }

    @Test func aimInputKeepsTheWordWhenItCantTranslate() async {
        let word = await AimLanguage.wordForMatching("keys", lang: "es") { _, _, _ in nil }
        #expect(word == "keys")
        let english = await AimLanguage.wordForMatching("mug", lang: "en") { _, _, _ in "WRONG" }
        #expect(english == "mug")
    }

    @Test func voicePrefixForChinese() {
        #expect(YourLanguageVoice.voicePrefix("zh-Hans") == "zh-CN")
        #expect(YourLanguageVoice.voicePrefix("fr") == "fr")
    }

    @Test func englishVoiceIsTheChosenOne() {
        let r = YourLanguageVoice.prepare("Hello", lang: "en", selected: "no-such-voice")
        #expect(r.text == "Hello")
        #expect(r.voice?.language.hasPrefix("en") == true)
    }

    // Matt 2026-11-04: a cup is just "taza" in Spanish, never "taza de café"; hand-fixed
    // names skip the translator. Same as Android ObjectLabelTranslationsTest.
    @Test func spanishCupIsJustTaza() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cup-\(UUID().uuidString)")
        var asked: [String] = []
        let out = await ObjectLabelTranslations.loadOrBuild(dir, lang: "es",
            labels: ["Coffee cup", "Mug", "Measuring cup", "Zebra"]) { phrases in
            asked = phrases
            return phrases.map { $0 == "zebra" ? "cebra" : "taza de" }
        }
        #expect(out == ["taza", "taza", "taza medidora", "cebra"])
        #expect(ObjectLabelTranslations.exact["es"]?["Coffee cup"] == "taza")
        #expect(asked.count == 4)
    }
}
