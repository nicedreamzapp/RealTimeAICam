@testable import RealTime_Ai_Cam
import CoreGraphics
import Foundation
import Testing

/// Live Cam's money counting (LiveMoney.swift). 11/4 Matt's videos: seven bills worth $129 came back "$600",
/// "four $100", "$7 total" and "$36". These pin the parts that are plain logic: one bill is one bill no matter
/// how many numerals it shows, the total is added in code, and anything unsure is said as unsure, never as a total.
struct LiveMoneyGroupingTests {
    /// A bill-shaped rectangle (156 x 66 at `scale`), y up, centred on (x, y).
    static func bill(_ x: CGFloat, _ y: CGFloat, scale: CGFloat = 1, turned: Bool = false) -> LiveMoney.Quad {
        let w = 156 * scale / 2, h = 66 * scale / 2
        let (a, b) = turned ? (h, w) : (w, h)
        return LiveMoney.Quad(corners: [CGPoint(x: x - a, y: y + b), CGPoint(x: x + a, y: y + b),
                                        CGPoint(x: x + a, y: y - b), CGPoint(x: x - a, y: y - b)])
    }
    static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> LiveMoney.Quad {
        LiveMoney.Quad(corners: [CGPoint(x: x, y: y + h), CGPoint(x: x + w, y: y + h), CGPoint(x: x + w, y: y), CGPoint(x: x, y: y)])
    }
    let frame: CGFloat = 1280 * 720

    @Test func fourCornerNumeralsOnOneBillAreOneBill() {
        // One $100: the bill, its printed inner border, and a box around each of its four corner "100"s.
        let b = Self.bill(500, 300, scale: 3)
        let inner = Self.bill(500, 300, scale: 2.7)
        let corners = [Self.box(290, 220, 40, 25), Self.box(670, 220, 40, 25), Self.box(290, 355, 40, 25), Self.box(670, 355, 40, 25)]
        let found = LiveMoney.bills(from: [b, inner] + corners, frameArea: frame)
        #expect(found.count == 1)
    }

    @Test func twoBillsSideBySideAreTwoAndTheBoxAroundBothIsDropped() {
        let a = Self.bill(300, 300, scale: 2), c = Self.bill(700, 300, scale: 2)
        let around = Self.box(120, 200, 760, 200)   // Vision's rectangle around both
        let found = LiveMoney.bills(from: [around, a, c], frameArea: frame)
        #expect(found.count == 2)
    }

    @Test func twoIdenticalOnesStillCountAsTwo() {
        let c = LiveMoney.count([LiveMoney.Bill(quad: Self.bill(300, 300, scale: 2), value: 1, cutOff: false),
                                 LiveMoney.Bill(quad: Self.bill(700, 300, scale: 2), value: 1, cutOff: false)])
        #expect(c.sure)
        #expect(c.total == 2)
    }

    @Test func aBillStandingOnItsEndIsStillBillShaped() {
        #expect(LiveMoney.billShape.contains(Self.bill(0, 0, turned: true).elongation))
        #expect(!LiveMoney.billShape.contains(Self.box(0, 0, 100, 100).elongation))   // a square is not a bill
    }

    @Test func overlappingBillsAreNeverTotalled() {
        let c = LiveMoney.count([LiveMoney.Bill(quad: Self.bill(300, 300, scale: 2), value: 100, cutOff: false),
                                 LiveMoney.Bill(quad: Self.bill(360, 320, scale: 2), value: 20, cutOff: false)])
        #expect(!c.sure)
        #expect(c.doubts.contains(.overlapping))
        #expect(!LiveMoney.sentence(c).contains("$120"))
    }

    // The real patch finder on a drawn picture: pale bills on a dark table.
    static func table(_ rects: [CGRect]) -> CGImage {
        let c = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.setFillColor(CGColor(red: 0.35, green: 0.25, blue: 0.18, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
        c.setFillColor(CGColor(red: 0.85, green: 0.87, blue: 0.82, alpha: 1))
        for r in rects { c.fill(r) }
        return c.makeImage()!
    }

    @Test func spreadOutBillsAreFoundOneEach() {
        let img = Self.table([CGRect(x: 80, y: 80, width: 312, height: 132), CGRect(x: 520, y: 80, width: 312, height: 132),
                              CGRect(x: 80, y: 420, width: 312, height: 132), CGRect(x: 760, y: 420, width: 312, height: 132)])
        let bills = LiveMoney.paperBlobs(in: img).filter(\.billLike)
        #expect(bills.count == 4)
    }

    @Test func aFanIsOnePatchThatIsNotBillShaped() {
        // Three bills fanned over each other.
        let img = Self.table([CGRect(x: 300, y: 200, width: 312, height: 132), CGRect(x: 360, y: 260, width: 312, height: 132),
                              CGRect(x: 420, y: 320, width: 312, height: 132)])
        let blobs = LiveMoney.paperBlobs(in: img)
        #expect(blobs.count == 1)
        #expect(blobs.first?.billLike == false)
    }
}

struct LiveMoneyReadingTests {
    @Test func bothQuestionsMustAgreeOnOneView() {
        #expect(LiveMoney.agreed([(20, 20), (2, 10)]) == 20)     // upside down it misread, right way up it agreed
        #expect(LiveMoney.agreed([(20, 20), (2, 2)]) == nil)     // two views agreeing on different values: not read
        #expect(LiveMoney.agreed([(1, 1), (1, 1)]) == 1)
        #expect(LiveMoney.agreed([(5, 20), (2, 10)]) == nil)     // nothing agreed
        #expect(LiveMoney.agreed([(3, 3), (5, 5)]) == nil)       // "3/3" is a misread view, not a missing one
    }

    @Test func modelAnswersBecomeValues() {
        #expect(LiveMoney.modelVote("100") == 100)
        #expect(LiveMoney.modelVote("$20") == 20)
        #expect(LiveMoney.modelVote("One dollar") == 1)
        #expect(LiveMoney.modelVote("The bill is worth") == nil)
        #expect(LiveMoney.modelVote("40") == nil)
    }

    @Test func printedWordsBeatNumeralsAndDistrictNumbersDontCount() {
        // A $1 from San Francisco prints "12" four times and "L" for the district: no denomination from that.
        #expect(LiveMoney.ocrVotes(["12", "L 06733670 B", "12", "THE UNITED STATES OF AMERICA"]).numeral == nil)
        #expect(LiveMoney.ocrVotes(["ONE HUNDRED DOLLARS", "100", "100"]) == (100, 100))
        #expect(LiveMoney.ocrVotes(["TWENTY DOLLARS"]).word == 20)
        #expect(LiveMoney.decide(word: 20, numeral: nil, model: 20) == 20)
        #expect(LiveMoney.decide(word: 5, numeral: nil, model: 100) == nil)   // printed word and model disagree: not read
        #expect(LiveMoney.decide(word: nil, numeral: nil, model: 5) == 5)
    }

    @Test func serialNumbersAreReadTheSameWayEveryTime() {
        #expect(LiveMoney.serials(in: "PE 36534546 K") == ["PE36534546K"])
        #expect(LiveMoney.serials(in: "RL:06290327 A") == ["RL06290327A"])
        #expect(LiveMoney.serials(in: "L 06733670 B") == ["L06733670B"])
        #expect(LiveMoney.serials(in: "SERIES 2017 A").isEmpty)
    }
}

struct LiveMoneyAnswerTests {
    static func bills(_ values: [Int?]) -> [LiveMoney.Bill] {
        values.enumerated().map { i, v in
            LiveMoney.Bill(quad: LiveMoneyGroupingTests.bill(CGFloat(100 + i * 200), 300), value: v, cutOff: false)
        }
    }

    @Test func mattsSevenBillsAreOneTwentyNine() {
        let c = LiveMoney.count(Self.bills([1, 100, 1, 5, 1, 20, 1]))
        #expect(c.sure)
        #expect(c.total == 129)
        #expect(LiveMoney.sentence(c) == "$129 in seven bills: one hundred, one twenty, one five and four ones.")
    }

    @Test func anUnreadBillIsNeverGuessed() {
        let c = LiveMoney.count(Self.bills([100, 20, 5, 1, 1, nil, nil]))
        #expect(!c.sure)
        let s = LiveMoney.sentence(c)
        #expect(s.hasPrefix("I see seven bills, and I can read five: a $100, a $20, a $5 and two $1s."))
        #expect(s.contains("the other two"))
        #expect(!s.contains("$127"))
    }

    @Test func overlapSaysWhatItCanReadAndAFloorNeverATotal() {
        var c = LiveMoney.count([], pile: [100, 20])
        c.atLeast = 3
        let s = LiveMoney.sentence(c)
        #expect(s.contains("at least three bills"))
        #expect(s.contains("at least one $100"))
        #expect(s.contains("Spread them out"))
        #expect(!s.contains("$120"))
    }

    @Test func nothingThereSaysHowToShowIt() {
        #expect(LiveMoney.sentence(LiveMoney.count([])).hasPrefix("I don't see any bills"))
    }

    @Test func aBillCutOffAtTheEdgeStopsTheTotal() {
        var b = Self.bills([100, 20])
        b[1].cutOff = true
        let c = LiveMoney.count(b)
        #expect(!c.sure)
        #expect(LiveMoney.sentence(c).contains("cut off"))
    }

    @Test func framesAreFusedBillByBill() {
        var a = LiveMoney.count(Self.bills([100, nil, 1])); a.size = CGSize(width: 1280, height: 720)
        var b = LiveMoney.count(Self.bills([100, 20, 1])); b.size = a.size
        let f = LiveMoney.fuse([a, b])
        #expect(f?.sure == true)
        #expect(f?.total == 121)
        // The same bill read as two different values in two frames: not read.
        var c = LiveMoney.count(Self.bills([100, 10, 1])); c.size = a.size
        #expect(LiveMoney.fuse([b, c])?.sure == false)
        // A different number of bills in each frame: no fusing.
        var d = LiveMoney.count(Self.bills([100, 20])); d.size = a.size
        #expect(LiveMoney.fuse([b, d]) == nil)
    }

    @Test func followUpsComeFromTheLastCount() {
        let c = LiveMoney.count(Self.bills([1, 100, 1, 5, 1, 20, 1]))
        #expect(LiveMoney.followUp("how many ones are there", last: c) == "Four $1s, out of seven bills worth $129.")
        #expect(LiveMoney.followUp("How many fives?", last: c) == "One $5, out of seven bills worth $129.")
        #expect(LiveMoney.followUp("how many tens", last: c) == "No $10s, out of seven bills worth $129.")
        var m = MoneyMemory()
        m.note(c, at: Date(timeIntervalSince1970: 0))
        #expect(m.recent(at: Date(timeIntervalSince1970: 30)) != nil)
        #expect(m.recent(at: Date(timeIntervalSince1970: 90)) == nil)
    }
}

struct LiveMoneyQuestionTests {
    @Test func moneyQuestionsAsHeard() {
        for q in ["How much money do you see right now?", "How much money is that right there?", "how many total dollars is it",
                  "Count the bills", "how many 20s are there", "How many twenties are there?", "what's the total of these bills",
                  "how much cash is this", "How many ones are there?", "What bill is this?", "how many dollar bills"] {
            #expect(LiveMoney.isMoneyQuestion(q), "\(q)")
        }
        for q in ["What do you see?", "how many people are here", "which ones are ripe", "how much does a car cost",
                  "what changed", "is this a dog"] {
            #expect(!LiveMoney.isMoneyQuestion(q), "\(q)")
        }
    }

    @Test func denominationsAsHeard() {
        #expect(LiveMoney.askedDenomination("how many twenties") == 20)
        #expect(LiveMoney.askedDenomination("how many 100s") == 100)
        #expect(LiveMoney.askedDenomination("how many five dollar bills") == 5)
        #expect(LiveMoney.askedDenomination("how much is it") == nil)
    }

    @Test func moneyGetsTheSharperPhoto() {
        #expect(LiveWords.needsDetail("how much money is that"))
        #expect(LiveWords.needsDetail("what bills are these"))
    }
}
