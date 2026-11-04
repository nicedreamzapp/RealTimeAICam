@testable import RealTime_Ai_Cam
import Foundation
import Testing

// Same cases as Android's ObjectLabelTranslationsTest.kt.
struct ObjectLabelTranslationsTests {
    private var labels: [String] { ObjectLabelCache.labels }

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("labels-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func labelListIsTheDetectorsSixHundredOne() {
        #expect(labels.count == 601)
    }

    @Test func everyContextKeyIsARealLabel() {
        let set = Set(labels)
        let missing = ObjectLabelTranslations.context.keys.filter { !set.contains($0) }
        #expect(missing.isEmpty, "not in class_names.txt: \(missing)")
    }

    @Test func ambiguousLabelsGetContext() {
        #expect(ObjectLabelTranslations.sourcePhrase("Mouse") == "mouse (animal)")
        #expect(ObjectLabelTranslations.sourcePhrase("Computer mouse") == "computer mouse")
        #expect(ObjectLabelTranslations.sourcePhrase("Bat (Animal)") == "bat (flying animal)")
        #expect(ObjectLabelTranslations.sourcePhrase("Baseball bat") == "baseball bat")
        #expect(ObjectLabelTranslations.sourcePhrase("Glasses") == "eyeglasses")
        #expect(ObjectLabelTranslations.sourcePhrase("Wine glass") == "wine glass")
        #expect(ObjectLabelTranslations.sourcePhrase("Stool") == "stool (seat)")
        #expect(ObjectLabelTranslations.sourcePhrase("Tie") == "necktie")
        #expect(ObjectLabelTranslations.sourcePhrase("Ruler") == "ruler (measuring tool)")
        #expect(ObjectLabelTranslations.sourcePhrase("Zebra") == "zebra")
    }

    @Test func sameContextMapAsAndroid() {
        #expect(ObjectLabelTranslations.context.count == 60)
        #expect(ObjectLabelTranslations.mapVersion == 2)
    }

    @Test func bracketNotesAreDroppedFromAnswers() {
        #expect(ObjectLabelTranslations.cleanOutput("ratón (animal)") == "ratón")
        #expect(ObjectLabelTranslations.cleanOutput(" murciélago  (animal volador) ") == "murciélago")
        #expect(ObjectLabelTranslations.cleanOutput("taburete [asiento]") == "taburete")
        #expect(ObjectLabelTranslations.cleanOutput("鼠标（电脑）") == "鼠标")
        #expect(ObjectLabelTranslations.cleanOutput("souris d'ordinateur") == "souris d'ordinateur")
    }

    @Test func leadingArticlesAreDropped() {
        #expect(ObjectLabelTranslations.cleanOutput("los anteojos", lang: "es") == "anteojos")
        #expect(ObjectLabelTranslations.cleanOutput("La souris (animal)", lang: "fr") == "souris")
        #expect(ObjectLabelTranslations.cleanOutput("l'ordinateur", lang: "fr") == "ordinateur")
        #expect(ObjectLabelTranslations.cleanOutput("die Brille", lang: "de") == "Brille")
        #expect(ObjectLabelTranslations.cleanOutput("la", lang: "es") == "la")
        #expect(ObjectLabelTranslations.cleanOutput("los anteojos", lang: "ja") == "los anteojos")
    }

    @Test func serializeParseRoundTrip() {
        let names = ["ratón", "dice \"hola\"", "back\\slash", "línea\nnueva", "Ж"]
        let data = ObjectLabelTranslations.serialize(lang: "es", signature: "abc", translated: names)
        #expect(ObjectLabelTranslations.parse(data, lang: "es", signature: "abc", expectedCount: names.count) == names)
        #expect(ObjectLabelTranslations.parse(data, lang: "fr", signature: "abc", expectedCount: names.count) == nil)
        #expect(ObjectLabelTranslations.parse(data, lang: "es", signature: "xyz", expectedCount: names.count) == nil)
        #expect(ObjectLabelTranslations.parse(data, lang: "es", signature: "abc", expectedCount: names.count + 1) == nil)
        #expect(ObjectLabelTranslations.parse(Data("{\"lang\":\"es\",\"signa".utf8), lang: "es", signature: "abc", expectedCount: 1) == nil)
    }

    @Test func builtOnceThenReadFromTheFile() async {
        let dir = tempDir()
        let labels = self.labels
        var calls = 0
        let first = await ObjectLabelTranslations.loadOrBuild(dir, lang: "es", labels: labels) { phrases in
            calls += phrases.count
            return phrases.map { "es:\($0)" }
        }
        #expect(calls == labels.count)
        #expect(first?.count == labels.count)
        #expect(first?[labels.firstIndex(of: "Mouse")!] == "es:mouse") // "(animal)" dropped
        #expect(first?[labels.firstIndex(of: "Computer mouse")!] == "es:computer mouse")
        #expect(FileManager.default.fileExists(atPath: ObjectLabelTranslations.cacheURL(dir, lang: "es").path))
        let start = Date()
        let second = await ObjectLabelTranslations.loadOrBuild(dir, lang: "es", labels: labels) { phrases in
            calls += phrases.count
            return phrases.map { _ in "WRONG" }
        }
        #expect(calls == labels.count) // no translating the second time
        #expect(second == first)
        #expect(Date().timeIntervalSince(start) < 0.5) // read from the file: instant
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func changedListRebuilds() async {
        let dir = tempDir()
        let small = ["Mouse", "Zebra"]
        _ = await ObjectLabelTranslations.loadOrBuild(dir, lang: "fr", labels: small) { $0.map { "fr:\($0)" } }
        let changed = ["Mouse", "Zebra", "Cup"]
        #expect(ObjectLabelTranslations.signature(small) != ObjectLabelTranslations.signature(changed))
        #expect(ObjectLabelTranslations.load(dir, lang: "fr", labels: changed) == nil)
        let rebuilt = await ObjectLabelTranslations.loadOrBuild(dir, lang: "fr", labels: changed) { $0.map { "fr2:\($0)" } }
        #expect(rebuilt == ["fr2:mouse", "fr2:zebra", "fr2:cup"])
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func halfBuiltListIsNeverSaved() async {
        let dir = tempDir()
        let out = await ObjectLabelTranslations.loadOrBuild(dir, lang: "de", labels: ["Mouse", "Zebra"]) { phrases in
            phrases.map { $0 == "zebra" ? nil : "x" }
        }
        #expect(out == nil)
        #expect(!FileManager.default.fileExists(atPath: ObjectLabelTranslations.cacheURL(dir, lang: "de").path))
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func eachLanguageHasItsOwnFile() async {
        let dir = tempDir()
        _ = await ObjectLabelTranslations.loadOrBuild(dir, lang: "es", labels: ["Mouse"]) { _ in ["ratón"] }
        _ = await ObjectLabelTranslations.loadOrBuild(dir, lang: "fr", labels: ["Mouse"]) { _ in ["souris"] }
        #expect(ObjectLabelTranslations.load(dir, lang: "es", labels: ["Mouse"]) == ["ratón"])
        #expect(ObjectLabelTranslations.load(dir, lang: "fr", labels: ["Mouse"]) == ["souris"])
        try? FileManager.default.removeItem(at: dir)
    }
}
