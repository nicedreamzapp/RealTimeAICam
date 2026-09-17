@testable import RealTime_Ai_Cam
import Foundation
import Testing

// Looking for a dog or a cat also finds its breeds (YOLOE often says
// "samoyed" or "persian cat" for the animal Matt is pointing at).
struct HelpMeAimLookAlikeTests {
    private let names = ["dog", "samoyed", "poodle", "cat", "persian cat", "pet", "key", "wolf"]

    @Test func dogFindsBreeds() throws {
        let m = try #require(AimVocabulary.match("dog", classNames: names))
        #expect(m.spokenName == "dog")
        #expect(m.classNames == ["dog", "poodle", "samoyed"])
        #expect(Set(m.classIDs) == [0, 1, 2])
        #expect(AimSubject.object(m).spokenName == "a dog")
    }

    @Test func catFindsBreedsButNotDogs() throws {
        let m = try #require(AimVocabulary.match("my cats", classNames: names))
        #expect(m.classNames == ["cat", "persian cat"])
        #expect(!m.classIDs.contains(1))
    }

    @Test func petIsNotABreedAndOtherWordsAreUntouched() throws {
        #expect(!AimVocabulary.lookAlikes(of: "dog").contains("pet"))
        #expect(AimVocabulary.lookAlikes(of: "dog").contains("samoyed"))
        let k = try #require(AimVocabulary.match("keys", classNames: names))
        #expect(k.classNames == ["key"])
        let guide = try #require(AimVocabulary.match("guide dog", classNames: names))
        #expect(guide.classNames.contains("samoyed"))
    }

    @Test func realVocabularyDogIncludesSamoyed() throws {
        let all = AimObjectFinder.loadClassNames()
        let m = try #require(AimVocabulary.match("dog", classNames: all))
        #expect(m.classNames.first == "dog")
        #expect(m.classNames.contains("samoyed"))
        #expect(m.classNames.contains("poodle"))
        let c = try #require(AimVocabulary.match("cat", classNames: all))
        #expect(c.classNames.contains("persian cat"))
    }
}
