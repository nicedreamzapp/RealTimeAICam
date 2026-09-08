@testable import RealTime_Ai_Cam
import Testing

struct MoneyCrossCheckTests {
    @Test func agreesWhenOCRHasTheSameAmount() {
        let r = MoneyCrossCheck.reconcile(sentence: "Your bill is $1,234.50, due June 3.",
                                          ocrText: "AMOUNT DUE $ 1,234.50")
        #expect(r.agreed == true)
        #expect(r.sentence == "Your bill is $1,234.50, due June 3.")
    }

    @Test func hedgesWhenOCRDisagrees() {
        let r = MoneyCrossCheck.reconcile(sentence: "Your bill is $126.40", ocrText: "Total $128.40")
        #expect(r.agreed == false)
        #expect(r.sentence == "Your bill is $126.40." + MoneyCrossCheck.hedge)
    }

    @Test func leavesSentenceAloneWhenOCRSawNoMoney() {
        let r = MoneyCrossCheck.reconcile(sentence: "Your bill is $126.40.", ocrText: "no numbers")
        #expect(r.agreed == nil)
        #expect(r.sentence == "Your bill is $126.40.")
    }

    @Test func nothingToCompareWhenSentenceHasNoMoney() {
        let r = MoneyCrossCheck.reconcile(sentence: "An advertisement from a car dealer.", ocrText: "$19,999")
        #expect(r.agreed == nil)
    }
}
