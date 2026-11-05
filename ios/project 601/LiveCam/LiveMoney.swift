// Live Cam counting money (11/4, Matt's three videos: "10 bills, five $20s", "$600", "four $100", "$7 total" for
// seven bills worth $129). The model used to guess the total from one 512 px look, and one $100's four corner
// numerals came out as four $100s. Now the code counts:
//   1. find each bill as its own rectangle in the full camera frame (Vision), one rectangle = one bill, so the
//      four "100"s in the corners of one bill are one bill;
//   2. read each bill on its own, straightened and cropped: Apple's text recognizer looks for the printed words and
//      numerals, and the model answers one tiny question about that one bill ("what is it worth?");
//   3. add it up in code, and say the breakdown;
//   4. say so when it can't be sure (bills overlapping, one cut off at the edge, one it can't read, frames that
//      disagree) and ask for the bills to be spread out. For someone who can't see the bills, "I can see a $100 and
//      a $20, spread them out so I can count the rest" beats a confident wrong total.
// No UIKit here: the Mac replay (ios/tools/money-replay) compiles this same file.
import CoreGraphics
import CoreImage
import Foundation
import Vision

enum LiveMoney {
    static let denominations = [1, 2, 5, 10, 20, 50, 100]

    // MARK: - Which questions are about money

    /// "How much money is this", "count the bills", "what's the total", "how many twenties". Allows for what the
    /// speech recognizer writes ("how much is that dollars", "how many 20s", "20 dollar bills").
    static func isMoneyQuestion(_ q: String) -> Bool {
        let t = " " + LiveWords.normalize(q) + " "
        let money = [" money ", " cash ", " bill ", " bills ", " dollar ", " dollars ", " buck ", " bucks ", " coin ", " coins ",
                     " currency ", " usd ", " 20s ", " 100s ", " twenties ", " fifties ", " hundreds "]
        let asking = [" how much ", " how many ", " count ", " total ", " add ", " sum ", " worth ", " what bill ", " which bill ",
                      " what kind of bill ", " is this a ", " is that a ", " what is this ", " what s this ", " whats this ",
                      " what is that ", " what s that ", " whats that ", " what do you see ", " what are these ", " what are those ",
                      " what bills ", " which bills ", " is it a "]
        if money.contains(where: { t.contains($0) }) && asking.contains(where: { t.contains($0) }) { return true }
        // "How many ones / fives / tens": the plain plurals mean bills only after "how many".
        if t.contains(" how many "), [" ones ", " fives ", " tens ", " 1s ", " 5s ", " 10s ", " 50s ", " singles "].contains(where: { t.contains($0) }) { return true }
        return false
    }

    /// A short follow-up to a money answer that just happened: "count it", "add it up", "what's the total",
    /// "how many ones", "are you sure". Only used within `MoneyMemory.maxAge` of the last count, and never for a
    /// plain "how many" (that could be about anything).
    static func isFollowUp(_ q: String) -> Bool {
        let t = " " + LiveWords.normalize(q) + " "
        return [" count it ", " count them ", " count again ", " total ", " add it ", " add them ", " sum ", " are you sure ",
                " ones ", " fives ", " tens ", " twenties ", " fifties ", " hundreds ", " twos ", " each bill ",
                " every bill ", " which bills ", " what bills "].contains { t.contains($0) }
    }

    /// "How many twenties" -> 20. nil when the question names no denomination.
    static func askedDenomination(_ q: String) -> Int? {
        let t = " " + LiveWords.normalize(q) + " "
        let names: [(Int, [String])] = [
            (100, [" hundreds ", " 100s ", " hundred dollar ", " 100 dollar ", " hundred bill"]),
            (50, [" fifties ", " 50s ", " fifty dollar ", " 50 dollar "]),
            (20, [" twenties ", " 20s ", " twenty dollar ", " 20 dollar "]),
            (10, [" tens ", " 10s ", " ten dollar ", " 10 dollar "]),
            (5, [" fives ", " 5s ", " five dollar ", " 5 dollar "]),
            (2, [" twos ", " 2s ", " two dollar ", " 2 dollar "]),
            (1, [" ones ", " 1s ", " one dollar ", " 1 dollar ", " singles "]),
        ]
        return names.first { $0.1.contains { t.contains($0) } }?.0
    }

    // MARK: - Geometry (pure)

    /// Four corners in pixels, y up (Vision's and Core Image's way round).
    struct Quad: Equatable {
        var corners: [CGPoint]   // tl, tr, br, bl once `ordered`
        var center: CGPoint { CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4) }
        var area: CGFloat {
            var s: CGFloat = 0
            for i in 0 ..< 4 { let a = corners[i], b = corners[(i + 1) % 4]; s += a.x * b.y - b.x * a.y }
            return abs(s) / 2
        }
        /// Mean of the two long edges over the mean of the two short edges (a US bill is 156 x 66 mm, 2.36).
        var elongation: CGFloat {
            let d = (0 ..< 4).map { i in hypot(corners[i].x - corners[(i + 1) % 4].x, corners[i].y - corners[(i + 1) % 4].y) }
            let a = (d[0] + d[2]) / 2, b = (d[1] + d[3]) / 2
            return max(a, b) / max(1, min(a, b))
        }
        func contains(_ p: CGPoint) -> Bool {
            var sign: CGFloat = 0
            for i in 0 ..< 4 {
                let a = corners[i], b = corners[(i + 1) % 4]
                let c = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                if c != 0 { if sign == 0 { sign = c } else if (c > 0) != (sign > 0) { return false } }
            }
            return true
        }
        /// Corners clockwise (y up) starting at the top left of the bill read the long way: tl, tr, br, bl.
        var ordered: Quad {
            let c = center
            var p = corners.sorted { atan2($0.y - c.y, $0.x - c.x) > atan2($1.y - c.y, $1.x - c.x) }
            func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
            if d(p[0], p[1]) + d(p[2], p[3]) < d(p[1], p[2]) + d(p[3], p[0]) { p = [p[1], p[2], p[3], p[0]] }
            return Quad(corners: p)
        }
        /// Share of this quad's area that `other` covers (sampled on a 12 x 12 grid inside this quad).
        func covered(by other: Quad) -> Double {
            let o = ordered.corners
            var inside = 0, hit = 0
            for i in 0 ..< 12 {
                for j in 0 ..< 12 {
                    let u = (CGFloat(i) + 0.5) / 12, v = (CGFloat(j) + 0.5) / 12
                    let top = CGPoint(x: o[0].x + (o[1].x - o[0].x) * u, y: o[0].y + (o[1].y - o[0].y) * u)
                    let bot = CGPoint(x: o[3].x + (o[2].x - o[3].x) * u, y: o[3].y + (o[2].y - o[3].y) * u)
                    let p = CGPoint(x: top.x + (bot.x - top.x) * v, y: top.y + (bot.y - top.y) * v)
                    inside += 1
                    if other.contains(p) { hit += 1 }
                }
            }
            return inside == 0 ? 0 : Double(hit) / Double(inside)
        }
        func touchesEdge(width: CGFloat, height: CGFloat, margin: CGFloat) -> Bool {
            corners.contains { $0.x < margin || $0.y < margin || $0.x > width - margin || $0.y > height - margin }
        }
    }

    /// Bill-shaped long/short ratio. A 2.36 bill seen at a slant, its long side pointing away, reads as low as 1.4.
    static let billShape: ClosedRange<CGFloat> = 1.3 ... 3.6

    /// The rectangles Vision found, cut down to one per bill: bill-shaped, not a tiny fleck, and an inner border
    /// (the printed frame inside a bill) folded into the bill around it. A rectangle around two or more bills is
    /// a group, not a bill, so it is dropped.
    static func bills(from rects: [Quad], frameArea: CGFloat) -> [Quad] {
        var c = rects.map(\.ordered).filter { billShape.contains($0.elongation) && $0.area > frameArea * 0.008 }
        c.sort { $0.area > $1.area }
        // A rectangle that holds two or more others whole is a group of bills.
        c = c.filter { big in c.filter { $0 != big && $0.area < big.area * 0.8 && $0.covered(by: big) > 0.85 }.count < 2 }
        var kept: [Quad] = []
        for q in c {   // largest first: an inner border sits inside its bill
            if kept.contains(where: { q.covered(by: $0) > 0.7 }) { continue }
            kept.append(q)
        }
        return kept
    }

    // MARK: - Reading one bill (pure)

    /// Denominations named by the words and numerals Apple's recognizer read on one straightened bill.
    /// Words are strong ("ONE HUNDRED", "TWENTY"); bare numerals are weak, because a $1 also carries its Federal
    /// Reserve district number four times ("12", "10", "5", "2" and "1" all occur), so they only count when the
    /// same numeral is read at least twice.
    static func ocrVotes(_ lines: [String]) -> (word: Int?, numeral: Int?) {
        let text = " " + lines.joined(separator: " ").uppercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }.reduce(into: "") { $0.append($1) } + " "
        var words: Set<Int> = []
        if text.contains(" HUNDRED ") { words.insert(100) }
        else if text.contains(" ONE DOLLAR ") || text.contains(" ONE ONE ") { words.insert(1) }
        for (w, v) in [(" TWO ", 2), (" FIVE ", 5), (" TEN ", 10), (" TWENTY ", 20), (" FIFTY ", 50)] where text.contains(w) { words.insert(v) }
        let tokens = text.split(separator: " ").map(String.init)
        var n: [Int: Int] = [:]
        for t in tokens { if let v = Int(t), denominations.contains(v) { n[v, default: 0] += 1 } }
        let numeral = n.filter { $0.value >= 2 }.max { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }?.key
        return (words.count == 1 ? words.first : nil, numeral)
    }

    /// The model's answer to "what is this bill worth?" as a denomination, or nil if it isn't one.
    static func modelVote(_ text: String?) -> Int? {
        guard let text else { return nil }
        let t = text.lowercased()
        let digits = t.split { !$0.isNumber }.compactMap { Int($0) }
        if let v = digits.first, denominations.contains(v) { return v }
        for (w, v) in [("hundred", 100), ("fifty", 50), ("twenty", 20), ("ten", 10), ("five", 5), ("two", 2), ("one", 1)]
        where t.contains(w) { return v }
        return nil
    }

    /// One bill's value from its votes. The model's read stands when nothing printed contradicts it; a printed
    /// word that disagrees with the model makes the bill unreadable rather than a coin toss.
    static func decide(word: Int?, numeral: Int?, model: Int?) -> Int? {
        switch (word, model) {
        case let (w?, m?): return w == m ? w : nil
        case let (w?, nil): return numeral == nil || numeral == w ? w : nil
        case let (nil, m?): return m
        case (nil, nil): return numeral
        }
    }

    // MARK: - The count (pure)

    struct Bill: Equatable { var quad: Quad; var value: Int?; var cutOff: Bool }

    /// Why there is no total: bills overlap, one is cut off at the edge, one couldn't be read, the frames
    /// disagreed, no bills at all, too many to trust, or a bill was seen that wasn't picked out.
    enum Doubt: String, Equatable { case overlapping, cutOff, unreadable, frames, none, tooMany, moreThanFound }

    struct Count: Equatable {
        var bills: [Bill]
        var doubts: [Doubt]
        /// Values made out inside overlapping bills (a fan, a stack): each one is there at least once, but how
        /// many of each, and how many bills in all, is not known.
        var pileValues: [Int] = []
        /// When bills overlap: the fewest bills that must be there (bills found whole, plus distinct serials or
        /// values read in the overlap). Never a count, only a floor.
        var atLeast = 0
        /// The frame the bills were found in (pixels), so bills can be matched between frames.
        var size = CGSize.zero
        var sure: Bool { doubts.isEmpty && !bills.isEmpty }
        var values: [Int] { bills.compactMap(\.value) }
        var total: Int { values.reduce(0, +) }
        /// Bills by value, largest first: [100: 1, 20: 1, 5: 1, 1: 4].
        var breakdown: [(value: Int, count: Int)] {
            Dictionary(grouping: values, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.value > $1.value }
        }
        func same(as o: Count) -> Bool { values.sorted() == o.values.sorted() && pileValues.sorted() == o.pileValues.sorted() }
        /// Everything it could read, singles counted, pile values once each.
        var readBreakdown: [(value: Int, count: Int)] {
            var d = Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
            for v in pileValues where d[v] == nil { d[v] = 1 }
            return d.map { ($0.key, $0.value) }.sorted { $0.value > $1.value }
        }
    }

    /// Bills overlapping one another by more than this share of the smaller one: a fan or a pile, not spread out.
    static let overlapLimit = 0.12

    static func count(_ bills: [Bill], moreSeen: Bool = false, pile: [Int]? = nil) -> Count {
        var doubts: [Doubt] = []
        if bills.isEmpty && pile == nil { doubts.append(.none) }
        if pile != nil { doubts.append(.overlapping) }
        let q = bills.map(\.quad)
        var overlap = false
        for i in q.indices { for j in q.indices where j > i {
            let (a, b) = q[i].area < q[j].area ? (q[i], q[j]) : (q[j], q[i])
            if a.covered(by: b) > overlapLimit { overlap = true }
        } }
        if overlap && pile == nil { doubts.append(.overlapping) }
        if bills.contains(where: \.cutOff) { doubts.append(.cutOff) }
        if bills.contains(where: { $0.value == nil }) { doubts.append(.unreadable) }
        if bills.count > 12 { doubts.append(.tooMany) }
        if moreSeen { doubts.append(.moreThanFound) }
        return Count(bills: bills, doubts: doubts, pileValues: Array(Set(pile ?? [])).sorted(by: >))
    }

    /// The same bills in a few frames, put together bill by bill: a bill read in one frame and not in another is
    /// read; a bill read as two different values is not. Only when every frame found the same bills, laid out
    /// the same way, with nothing worse than an unread bill (no overlap, nothing cut off or missed).
    static func fuse(_ counts: [Count]) -> Count? {
        guard let first = counts.first, counts.count > 1, !first.bills.isEmpty else { return nil }
        let structural: Set<Doubt> = [.overlapping, .cutOff, .moreThanFound, .none, .tooMany]
        guard counts.allSatisfy({ $0.bills.count == first.bills.count && Set($0.doubts).isDisjoint(with: structural) }) else { return nil }
        let diag = max(1, hypot(first.size.width, first.size.height))
        var reads: [[Int]] = first.bills.map { $0.value.map { [$0] } ?? [] }
        for c in counts.dropFirst() {
            var free = Array(c.bills.indices)
            for (i, b) in first.bills.enumerated() {
                // The nearest unmatched bill; the phone moves a little between frames, never a third of the picture.
                guard let j = free.min(by: { dist(c.bills[$0].quad.center, b.quad.center) < dist(c.bills[$1].quad.center, b.quad.center) }),
                      dist(c.bills[j].quad.center, b.quad.center) < diag * 0.12 else { return nil }
                free.removeAll { $0 == j }
                if let v = c.bills[j].value { reads[i].append(v) }
            }
        }
        var bills = first.bills
        for i in bills.indices { bills[i].value = Set(reads[i]).count == 1 ? reads[i].first : nil }
        var out = count(bills)
        out.size = first.size
        return out
    }
    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// The burst the app takes for one money question. A total is only spoken when two frames a moment apart
    /// agree on it (11/4 replay, Balanced: one frame missed the $5 and said "$124" with nothing to doubt it; the
    /// next frame found it). A bill unread in one frame can be read in the other (fused bill by bill). Overlap, a
    /// cut-off or a missed bill stops at once: a third of a second won't fix it.
    static func countBurst(maxFrames: Int = 3, frame: () -> CGImage?, ask: Ask?,
                           onLook: ((Count, [[String: Any]]) -> Void)? = nil) -> Count {
        var looks: [Count] = []
        while looks.count < max(2, maxFrames), let img = frame() {
            let (c, log) = look(img, ask: ask)
            onLook?(c, log)
            looks.append(c)
            if !Set(c.doubts).isSubset(of: [.unreadable]) { return c }
            if looks.count > 1, let f = fuse(looks), f.sure { return f }
        }
        guard let last = looks.last else { return Count(bills: [], doubts: [.none]) }
        if looks.count > 1, let f = fuse(looks) { return f }
        // Only one look, or looks that didn't line up: never a total from a single frame.
        if last.sure { var c = last; c.doubts = [.frames]; return c }
        return last
    }

    // MARK: - What it says (pure)

    static func spokenValue(_ v: Int) -> String {
        switch v {
        case 1: return "one"
        case 2: return "two"
        case 5: return "five"
        case 10: return "ten"
        case 20: return "twenty"
        case 50: return "fifty"
        case 100: return "hundred"
        default: return "\(v)"
        }
    }

    /// "one hundred, one twenty, one five and four ones".
    static func breakdownWords(_ b: [(value: Int, count: Int)]) -> String {
        let parts = b.map { v, n -> String in
            let name = spokenValue(v)
            let plural = v == 20 ? "twenties" : v == 50 ? "fifties" : v == 100 ? "hundreds" : name + "s"
            return n == 1 ? "one \(name)" : "\(number(n)) \(plural)"
        }
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    static func number(_ n: Int) -> String {
        let w = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        return n < w.count ? w[n] : "\(n)"
    }

    /// "a $100 and a $20", "two $1s".
    static func readable(_ b: [(value: Int, count: Int)], atLeast: Bool = false) -> String {
        let parts = b.map { v, n in n == 1 ? (atLeast ? "at least one $\(v)" : "a $\(v)") : "\(number(n)) $\(v)s" }
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    /// The whole answer. Sure: the total and the breakdown. Not sure: what it could read, never as a total, never
    /// a guess for a bill it couldn't read, and how to fix the shot.
    static func sentence(_ c: Count) -> String {
        if c.sure {
            let n = c.values.count
            if n == 1 { return "That's one $\(c.total) bill." }
            return "$\(c.total) in \(number(n)) bills: \(breakdownWords(c.breakdown))."
        }
        if c.doubts.contains(.none) {
            return "I don't see any bills I can count. Lay them flat on a table, spread out so none touch, hold the phone about a foot and a half above them, and ask me again."
        }
        let read = c.readBreakdown
        if c.doubts.contains(.overlapping) {
            let seen = read.isEmpty ? "I can't make out any of them yet." : "I can make out \(readable(read, atLeast: !c.pileValues.isEmpty))."
            let floor = c.atLeast >= 2 ? " There are at least \(number(c.atLeast)) bills." : ""
            return "Some of the bills overlap, so I can't count them or give you a total.\(floor) \(seen) Spread them out on the table so none overlap, and ask me again."
        }
        let n = c.bills.count, k = c.values.count
        let counted = n == 1 ? "I see one bill" : "I see \(number(n)) bills"
        let part = k == 0 ? "\(counted), but I can't read \(n == 1 ? "it" : "them") yet."
            : k == n ? "\(counted): \(readable(read))."
            : "\(counted), and I can read \(number(k)): \(readable(read))."
        if c.doubts.contains(.cutOff) { return part + " One is cut off at the edge, so there may be more. Move the phone back a little so every bill is in view, and ask me again." }
        if c.doubts.contains(.unreadable) {
            let other = k == 0 ? "them" : n - k == 1 ? "the other one" : "the other \(number(n - k))"
            return part + " Flatten them out and hold the phone a little closer so I can read \(other), and ask me again."
        }
        if c.doubts.contains(.moreThanFound) { return part + " But I can see part of another bill I couldn't pick out, so I'm not giving a total yet. Spread them out a little more and ask me again." }
        return part + " But my looks didn't agree, so I'm not giving a total yet. Hold the phone steady over the bills and ask me again."
    }

    /// "How many twenties?" right after a count: answered from the count, never a new guess.
    static func followUp(_ q: String, last c: Count) -> String {
        if let v = askedDenomination(q) {
            let n = c.values.filter { $0 == v }.count
            let lead = n == 0 ? "No $\(v)s" : n == 1 ? "One $\(v)" : "\(number(n).capitalized) $\(v)s"
            return c.sure ? "\(lead), out of \(number(c.values.count)) bills worth $\(c.total)." : "\(lead) that I could read, but I'm not sure I saw them all."
        }
        return sentence(c)
    }

    // MARK: - Vision (the part that needs the frame)

    /// Every rectangle Vision sees, in pixels.
    static func rectangles(in image: CGImage) -> [Quad] {
        let rq = VNDetectRectanglesRequest()
        rq.maximumObservations = 30
        rq.minimumAspectRatio = 0.2   // short / long, measured on the picture, so a slanted bill still qualifies
        rq.maximumAspectRatio = 0.7
        rq.minimumSize = 0.08
        rq.quadratureTolerance = 30
        rq.minimumConfidence = 0.3
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([rq]) } catch { return [] }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (rq.results ?? []).map { r in
            Quad(corners: [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft].map { CGPoint(x: $0.x * w, y: $0.y * h) })
        }
    }

    private static let ci = CIContext(options: [.useSoftwareRenderer: false])

    /// One bill straightened into its own landscape picture, `width` px wide.
    static func straightened(_ image: CGImage, _ q: Quad, width: CGFloat = 640) -> CGImage? {
        let o = q.ordered.corners
        guard let f = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        f.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        f.setValue(CIVector(cgPoint: o[0]), forKey: "inputTopLeft")
        f.setValue(CIVector(cgPoint: o[1]), forKey: "inputTopRight")
        f.setValue(CIVector(cgPoint: o[2]), forKey: "inputBottomRight")
        f.setValue(CIVector(cgPoint: o[3]), forKey: "inputBottomLeft")
        guard var out = f.outputImage, out.extent.width > 1 else { return nil }
        let s = width / out.extent.width
        out = out.transformed(by: CGAffineTransform(scaleX: s, y: s))
        return ci.createCGImage(out, from: out.extent.integral)
    }

    /// Serial numbers in recognised text: one or two letters, eight digits, a letter or a star ("PE 36534546 K",
    /// "L06733670B"). Spaces and a stray mark at the end are dropped, so the same serial read twice matches.
    static func serials(in line: String) -> [String] {
        let t = line.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ":", with: "")
        guard let re = try? NSRegularExpression(pattern: #"[A-Z]{1,2}\d{8}[A-Z*]"#) else { return [] }
        let ns = t as NSString
        return re.matches(in: t, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    struct Serial: Equatable { var text: String; var at: CGPoint }

    /// Every serial number in the frame, read both ways up, with where it is (pixels, y up), each serial once.
    static func serialsInFrame(_ image: CGImage) -> [Serial] {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        var out: [Serial] = []
        for o in [CGImagePropertyOrientation.up, .down] {
            let rq = VNRecognizeTextRequest()
            rq.recognitionLevel = .accurate
            rq.usesLanguageCorrection = false
            do { try VNImageRequestHandler(cgImage: image, orientation: o, options: [:]).perform([rq]) } catch { continue }
            for r in rq.results ?? [] {
                guard let line = r.topCandidates(1).first?.string else { continue }
                let b = r.boundingBox
                // Read upside down, the box is in the turned picture: turn it back.
                let p = o == .up ? CGPoint(x: b.midX * W, y: b.midY * H) : CGPoint(x: (1 - b.midX) * W, y: (1 - b.midY) * H)
                for s in serials(in: line) { out.append(Serial(text: s, at: p)) }
            }
        }
        // The front of a bill prints its serial twice: both places are kept (either one inside a bill ties the
        // serial to it), the same serial read at the same place both ways up only once.
        return out.reduce(into: [Serial]()) { acc, s in
            if !acc.contains(where: { $0.text == s.text && hypot($0.at.x - s.at.x, $0.at.y - s.at.y) < min(W, H) * 0.03 }) { acc.append(s) }
        }
    }

    /// The printed text on one straightened bill, read the right way up and upside down (a bill on a table is
    /// either way round).
    static func printedText(_ bill: CGImage) -> [String] { printedTextAndWayUp(bill).lines }

    /// The text, and which way up the bill is: the way that reads clearly more letters (nil when neither does,
    /// e.g. a blurry bill, and then the model is asked both ways up).
    static func printedTextAndWayUp(_ bill: CGImage) -> (lines: [String], upright: Bool?) {
        var lines: [String] = []
        var letters: [Int] = []
        for o in [CGImagePropertyOrientation.up, .down] {
            let rq = VNRecognizeTextRequest()
            rq.recognitionLevel = .accurate
            rq.usesLanguageCorrection = false
            do { try VNImageRequestHandler(cgImage: bill, orientation: o, options: [:]).perform([rq]) } catch { letters.append(0); continue }
            let got = (rq.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            lines += got
            letters.append(got.joined().filter(\.isLetter).count)
        }
        let up = letters.first ?? 0, down = letters.last ?? 0
        let wayUp: Bool? = max(up, down) >= 12 && max(up, down) >= 2 * min(up, down) ? up > down : nil
        return (lines, wayUp)
    }

    /// The two questions the model gets about each bill, each asked with the bill both ways up. 11/4 replay: a
    /// bill read upside down came back "$100" for a $5 with full confidence, while the right way up both questions
    /// said 5. A value counts only when both questions give it on the same view.
    static let modelSystem = "You read US paper money."
    static let worthQuestion = "How many dollars is this bill worth? Answer with one number."
    static let cornerQuestion = "What number is printed in the corners of this bill? Answer with just the number."
    /// A bill read by the model at this size: small enough to be quick, big enough for the corner numerals.
    static let modelLongSide = 384

    /// The value both questions agreed on, from each view (right way up, upside down). One value agreed on, and
    /// no other: that's the bill. None, or two different ones: the bill is not read.
    static func agreed(_ views: [(worth: Int?, corner: Int?)]) -> Int? {
        let ok = Set(views.compactMap { v -> Int? in
            guard let w = v.worth, w == v.corner else { return nil }
            return w
        })
        // Both questions agreeing on a number no bill carries ("3/3") is a misread view, not a missing one.
        if ok.contains(where: { !denominations.contains($0) }) { return nil }
        return ok.count == 1 ? ok.first : nil
    }

    static func wordNumber(_ text: String?) -> Int? {
        guard let t = text?.lowercased() else { return nil }
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        let toks = t.split { !$0.isLetter }.map(String.init)
        if toks.contains("several") || toks.contains("many") { return 99 }
        return toks.compactMap { words.firstIndex(of: $0).map { $0 + 1 } }.first
    }

    /// The first whole number in a model answer, whether or not a bill carries it.
    static func number(in text: String?) -> Int? {
        text.flatMap { $0.split { !$0.isNumber }.first.flatMap { Int($0) } }
    }

    /// How much fine printing a straightened patch has: mean step between neighbouring pixels on a small grey
    /// copy. Every bill is covered in engraving; a wall, a sheet of paper or a plate is smooth (11/4 replay: a
    /// white wall 12.8, bills 19 to 27).
    static func printDetail(_ image: CGImage) -> Double {
        let w = 160, h = 68
        var px = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        var g = 0.0, n = 0
        for y in 4 ..< h - 4 { for x in 4 ..< w - 4 {
            let i = y * w + x
            g += abs(Double(px[i]) - Double(px[i + 1])) + abs(Double(px[i]) - Double(px[i + w])); n += 1
        } }
        return n > 0 ? g / Double(n) : 0
    }
    static let minPrintDetail = 15.0

    static func upsideDown(_ image: CGImage) -> CGImage? {
        let o = CIImage(cgImage: image).oriented(.down)
        return ci.createCGImage(o, from: o.extent)
    }

    static func part(_ image: CGImage, _ r: CGRect) -> CGImage? {
        image.cropping(to: CGRect(x: r.minX * CGFloat(image.width), y: r.minY * CGFloat(image.height),
                                  width: r.width * CGFloat(image.width), height: r.height * CGFloat(image.height)).integral)
    }

    // MARK: - Paper on the table

    /// A light patch of paper found in the frame, fitted with a rectangle.
    struct Blob { var quad: Quad; var pixels: Int; var fill: Double; var billLike: Bool; var atEdge: Bool }

    /// Bills are pale and grey-green; a table, a hand or a floor is darker or more coloured. Every light,
    /// low-colour patch is found and fitted with a rectangle (its main direction from the patch's own spread).
    /// A lone bill is a full rectangle about 2.4 times as long as it is wide; bills that overlap merge into one
    /// patch that is not bill-shaped, which is how a fan or a pile is told apart from bills spread out.
    static func paperBlobs(in image: CGImage, side: Int = 360) -> [Blob] {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let s = CGFloat(side) / max(W, H)
        let w = max(8, Int(W * s)), h = max(8, Int(H * s))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            c.interpolationQuality = .medium
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return [] }
        // How paper-like each pixel is: bright and grey.
        var score = [Float](repeating: 0, count: w * h)
        var hist = [Int](repeating: 0, count: 256)
        // Warm room light makes white paper warm too (11/4 photo under a lamp: every bill came out orange), so warmth
        // counts from the least warm quarter of the picture, where the bills and other paper are, not from zero.
        var warmth: [Float] = []
        warmth.reserveCapacity(w * h / 4)
        for i in stride(from: 0, to: w * h, by: 4) where Int(px[i * 4]) + Int(px[i * 4 + 1]) + Int(px[i * 4 + 2]) > 72 {
            warmth.append(Float(px[i * 4]) - Float(px[i * 4 + 2]))
        }
        warmth.sort()
        let warmBase = warmth.isEmpty ? 0 : max(0, warmth[warmth.count / 4])
        for i in 0 ..< w * h {
            let r = Float(px[i * 4]), g = Float(px[i * 4 + 1]), b = Float(px[i * 4 + 2])
            let mx = max(r, g, b), mn = min(r, g, b)
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            guard lum > 24 else { continue }   // the black outside (and true shadow) never counts
            let sat = mx > 0 ? (mx - mn) / mx : 0
            // Wood, skin and cardboard are warm (much more red than blue); every bill is close to neutral.
            let warm = max(0, (r - b) - warmBase - 20)
            let v = max(0, min(255, lum * (1 - 1.6 * sat) - 2.5 * warm))
            score[i] = v
            hist[Int(v)] += 1
        }
        // Otsu: the split between "paper" and "everything else" that best separates the two.
        let total = hist.reduce(0, +)
        guard total > 0 else { return [] }
        var sumAll = 0.0
        for k in 0 ..< 256 { sumAll += Double(k * hist[k]) }
        var wB = 0, sumB = 0.0, best = 0.0, cut = 128
        for k in 0 ..< 256 {
            wB += hist[k]; if wB == 0 { continue }
            let wF = total - wB; if wF == 0 { break }
            sumB += Double(k * hist[k])
            let mB = sumB / Double(wB), mF = (sumAll - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; cut = k }
        }
        // Light on one side of the table and shade on the other moves the whole table's brightness, so a pixel
        // must also stand out from its neighbourhood (a window wider than a bill), not only clear the one split.
        var integral = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0 ..< h {
            var row = 0.0
            for x in 0 ..< w { row += Double(score[y * w + x]); integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row }
        }
        let r = max(4, max(w, h) / 6)
        var on = [Bool](repeating: false, count: w * h)
        for y in 0 ..< h { for x in 0 ..< w {
            let i = y * w + x
            guard score[i] > Float(cut) * 0.6 else { continue }
            let x0 = max(0, x - r), x1 = min(w, x + r + 1), y0 = max(0, y - r), y1 = min(h, y + r + 1)
            let sum = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
            let mean = sum / Double((x1 - x0) * (y1 - y0))
            if Double(score[i]) > mean + 10 || score[i] > Float(cut) * 1.25 { on[i] = true }
        } }
        // Open (shrink, then grow) once, so a thin bright bridge (a cable, a glint) doesn't join two bills.
        func step(_ m: [Bool], grow: Bool) -> [Bool] {
            var o = m
            for y in 0 ..< h { for x in 0 ..< w {
                var any = false, all = true
                for (dx, dy) in [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let xx = x + dx, yy = y + dy
                    let v = xx >= 0 && yy >= 0 && xx < w && yy < h ? m[yy * w + xx] : false
                    any = any || v; all = all && v
                }
                o[y * w + x] = grow ? any : all
            } }
            return o
        }
        on = step(step(on, grow: false), grow: true)
        // Fill the holes: a bill's portrait and dark printing sit inside its pale margin, and without this a bill
        // splits into pieces at the portrait (11/4 photo of two $1s, each cut in two).
        var outside = [Bool](repeating: false, count: w * h)
        var fillStack: [Int] = []
        for x in 0 ..< w { fillStack.append(x); fillStack.append((h - 1) * w + x) }
        for y in 0 ..< h { fillStack.append(y * w); fillStack.append(y * w + w - 1) }
        while let i = fillStack.popLast() {
            guard !on[i], !outside[i] else { continue }
            outside[i] = true
            let x = i % w, y = i / w
            if x > 0 { fillStack.append(i - 1) }
            if x < w - 1 { fillStack.append(i + 1) }
            if y > 0 { fillStack.append(i - w) }
            if y < h - 1 { fillStack.append(i + w) }
        }
        for i in 0 ..< w * h where !outside[i] { on[i] = true }
        let minPixels = max(20, w * h / 300)

        /// Connected patches of `mask`, each with its pixels.
        func patches(_ mask: [Bool]) -> [[Int]] {
            var seen = [Bool](repeating: false, count: w * h)
            var out: [[Int]] = []
            for start in 0 ..< w * h where mask[start] && !seen[start] {
                var pts: [Int] = []
                var stack = [start]
                seen[start] = true
                while let i = stack.popLast() {
                    pts.append(i)
                    let x = i % w, y = i / w
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                        let j = yy * w + xx
                        if mask[j] && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
                if pts.count >= minPixels { out.append(pts) }
            }
            return out
        }

        /// A rectangle fitted to one patch: direction from its spread, extent from the 1st to 99th percentile.
        func fit(_ pts: [Int]) -> Blob {
            var mx = 0.0, my = 0.0
            for i in pts { mx += Double(i % w); my += Double(i / w) }
            mx /= Double(pts.count); my /= Double(pts.count)
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for i in pts { let dx = Double(i % w) - mx, dy = Double(i / w) - my; sxx += dx * dx; syy += dy * dy; sxy += dx * dy }
            let th = 0.5 * atan2(2 * sxy, sxx - syy)
            let ux = cos(th), uy = sin(th)
            var a: [Double] = [], b: [Double] = []
            a.reserveCapacity(pts.count); b.reserveCapacity(pts.count)
            var edge = false
            for i in pts {
                let x = i % w, y = i / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { edge = true }
                let dx = Double(x) - mx, dy = Double(y) - my
                a.append(dx * ux + dy * uy); b.append(-dx * uy + dy * ux)
            }
            a.sort(); b.sort()
            func pct(_ v: [Double], _ p: Double) -> Double { v[min(v.count - 1, max(0, Int(Double(v.count - 1) * p)))] }
            let a0 = pct(a, 0.01), a1 = pct(a, 0.99), b0 = pct(b, 0.01), b1 = pct(b, 0.99)
            let len = max(1, a1 - a0 + 1), wid = max(1, b1 - b0 + 1)
            let fill = min(1, Double(pts.count) / (len * wid))
            let cx = mx + ux * (a0 + a1) / 2 - uy * (b0 + b1) / 2, cy = my + uy * (a0 + a1) / 2 + ux * (b0 + b1) / 2
            var corners: [CGPoint] = []
            for (sa, sb) in [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)] {
                let x = cx + ux * sa * len / 2 - uy * sb * wid / 2
                let y = cy + uy * sa * len / 2 + ux * sb * wid / 2
                corners.append(CGPoint(x: CGFloat(x) / s, y: H - CGFloat(y) / s))   // back to full size, y up
            }
            let q = Quad(corners: corners)
            return Blob(quad: q, pixels: pts.count, fill: fill, billLike: billShape.contains(q.elongation) && fill >= 0.78, atEdge: edge)
        }

        /// A patch that isn't bill-shaped may be a bill touching something pale (a lit patch of table, a white
        /// button): split it at its own brightness split and keep the parts if any of them is a bill.
        func split(_ pts: [Int], depth: Int) -> [Blob] {
            let whole = fit(pts)
            guard !whole.billLike, depth < 2, pts.count >= minPixels * 2 else { return [whole] }
            var hh = [Int](repeating: 0, count: 256)
            for i in pts { hh[Int(score[i])] += 1 }
            var all = 0.0
            for k in 0 ..< 256 { all += Double(k * hh[k]) }
            var nB = 0, sB = 0.0, top = 0.0, c2 = -1
            for k in 0 ..< 256 {
                nB += hh[k]; if nB == 0 { continue }
                let nF = pts.count - nB; if nF == 0 { break }
                sB += Double(k * hh[k])
                let d = sB / Double(nB) - (all - sB) / Double(nF)
                let between = Double(nB) * Double(nF) * d * d
                if between > top { top = between; c2 = k }
            }
            guard c2 >= 0 else { return [whole] }
            var m = [Bool](repeating: false, count: w * h)
            for i in pts where score[i] > Float(c2) { m[i] = true }
            m = step(step(m, grow: false), grow: true)
            let parts = patches(m).flatMap { split($0, depth: depth + 1) }
            return parts.contains(where: \.billLike) ? parts : [whole]
        }

        let blobs = patches(on).flatMap { split($0, depth: 0) }
        return blobs
    }

    /// The model, asked one question about one picture.
    typealias Ask = (_ image: CGImage, _ question: String) -> String?

    /// One picture read by the model both ways up, two questions each way. A value counts when both questions
    /// give it on one view and the other view doesn't agree on something else (11/4 replay: a $20 upside down came
    /// back "2/2" or "10/10" while the right way up said "20/20"; that bill stays unread rather than become a $2).
    /// The portrait was tried as a tie-break and named Abigail Adams on a $20, so it isn't used.
    static func modelRead(_ crop: CGImage, ask: Ask) -> (value: Int?, said: String) {
        var views: [(worth: Int?, corner: Int?)] = []
        var said: [String] = []
        for img in [crop, upsideDown(crop)].compactMap({ $0 }) {
            let w = ask(img, worthQuestion), c = ask(img, cornerQuestion)
            said.append("\(clean(w))/\(clean(c))")
            views.append((number(in: w) ?? modelVote(w), number(in: c) ?? modelVote(c)))
        }
        return (agreed(views), said.joined(separator: " "))
    }

    static func isYes(_ a: String?) -> Bool { (a ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("yes") }
    static let countQuestion = "How many paper money bills can you see in this picture, including ones that are partly hidden? Answer with one number."
    static let moneyQuestion = "Is there US paper money in this picture? Answer yes or no."

    private static func clean(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "_") }

    /// One frame counted. `ask` is the model (nil: printed text only).
    static func look(_ image: CGImage, ask: Ask?) -> (count: Count, log: [[String: Any]]) {
        let blobs = paperBlobs(in: image)
        var single = blobs.filter(\.billLike)
        // Bills Vision finds by their straight edges that no pale patch already covers (a bill on a pale table,
        // or one the patch search cut in two).
        let area = CGFloat(image.width * image.height)
        for q in bills(from: rectangles(in: image), frameArea: area)
        where !single.contains(where: { q.covered(by: $0.quad) > 0.4 || $0.quad.covered(by: q) > 0.4 }) {
            let edge = q.touchesEdge(width: CGFloat(image.width), height: CGFloat(image.height), margin: CGFloat(min(image.width, image.height)) * 0.01)
            single.append(Blob(quad: q, pixels: Int(q.area * pow(360 / CGFloat(max(image.width, image.height)), 2)), fill: 1, billLike: true, atEdge: edge))
        }
        // The size of one bill here: the middle of the bill-shaped patches.
        let one = single.map(\.pixels).sorted().dropFirst(single.count / 2).first
        // A patch that isn't bill-shaped but is at least as big as most of a bill: a fan, a pile, a stack.
        let piles = blobs.filter { !$0.billLike && Double($0.pixels) >= Double(one ?? Int.max) * 0.6
            || !$0.billLike && one == nil && $0.pixels >= paperMinPixels(image) * 6 }
        var out: [Bill] = []
        var log: [[String: Any]] = []
        var pileValues: [Int] = []
        var pileSerials: Set<String> = []
        var smoothMoney: [Quad] = []
        var anyPile = false
        // Serial numbers anywhere in the frame (both ways up): one serial is one bill, so the same bill is never
        // counted twice and two $1s side by side still count as two.
        let frameSerials = serialsInFrame(image)
        func read(_ crop: CGImage) -> (Int?, [String: Any]) {
            let (lines, upright) = printedTextAndWayUp(crop)
            let (word, numeral) = ocrVotes(lines)
            _ = upright   // which way up the text reads is logged, not trusted: one wrong guess made a $20 a $2
            let m = ask.map { modelRead(crop, ask: $0) }
            let value = decide(word: word, numeral: numeral, model: m?.value)
            return (value, ["word": word ?? 0, "numeral": numeral ?? 0, "model": m?.said ?? "", "value": value ?? 0])
        }
        for b in single {
            guard let crop = straightened(image, b.quad) else { continue }
            let detail = printDetail(crop)
            guard detail >= minPrintDetail else {
                // Smooth: a wall or a sheet of paper, or a bill under glare. If the model says it's money, it's a
                // bill that can't be read, never silently dropped (a dropped bill is a wrong total).
                var e: [String: Any] = ["x": Int(b.quad.center.x), "y": Int(b.quad.center.y), "skipped": "smooth", "detail": Int(detail)]
                if let ask, isYes(ask(crop, moneyQuestion)) {
                    e["skipped"] = nil; e["model"] = "smooth-but-money"; e["value"] = 0
                    smoothMoney.append(b.quad)
                }
                log.append(e)
                continue
            }
            var (value, entry) = read(crop)
            entry["x"] = Int(b.quad.center.x); entry["y"] = Int(b.quad.center.y)
            entry["cut"] = b.atEdge
            out.append(Bill(quad: b.quad, value: value, cutOff: b.atEdge))
            log.append(entry)
        }
        for p in piles {
            // A patch that isn't bill-shaped is often one bill touching something pale (a lit stretch of table, a
            // white button), so first look for whole bill rectangles inside it by their straight edges.
            let inside = rectanglesInside(image, p.quad).filter { r in !out.contains { r.covered(by: $0.quad) > 0.5 } }
            var found: [Quad] = []
            for q in inside {
                guard let crop = straightened(image, q), printDetail(crop) >= minPrintDetail else { continue }
                var (value, entry) = read(crop)
                entry["x"] = Int(q.center.x); entry["y"] = Int(q.center.y); entry["inPatch"] = true
                let cut = q.touchesEdge(width: CGFloat(image.width), height: CGFloat(image.height), margin: CGFloat(min(image.width, image.height)) * 0.01)
                entry["cut"] = cut
                out.append(Bill(quad: q, value: value, cutOff: cut))
                found.append(q)
                log.append(entry)
            }
            // What is left: read each quarter of the patch that no bill found above covers, so a corner numeral
            // of a bill underneath is read. Only money left over makes it a pile; table or paper is let go.
            // A patch that is too smooth for money is still read: a bill under glare or out of focus is smooth too
            // (11/4 replay: the $100 merged with a lit stretch of table was skipped, and the total came out $29).
            guard let crop = straightened(image, p.quad) else { continue }
            let detail = printDetail(crop)
            var seen: [Int: Int] = [:]   // value -> how many pieces read it
            var entry: [String: Any] = ["x": Int(p.quad.center.x), "y": Int(p.quad.center.y), "pile": true, "detail": Int(detail)]
            var quarters = [CGRect(x: 0, y: 0, width: 0.55, height: 0.55), CGRect(x: 0.45, y: 0, width: 0.55, height: 0.55),
                            CGRect(x: 0, y: 0.45, width: 0.55, height: 0.55), CGRect(x: 0.45, y: 0.45, width: 0.55, height: 0.55)]
            if found.isEmpty { quarters.insert(CGRect(x: 0, y: 0, width: 1, height: 1), at: 0) }
            let o = p.quad.ordered.corners
            func at(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
                let top = CGPoint(x: o[0].x + (o[1].x - o[0].x) * u, y: o[0].y + (o[1].y - o[0].y) * u)
                let bot = CGPoint(x: o[3].x + (o[2].x - o[3].x) * u, y: o[3].y + (o[2].y - o[3].y) * u)
                return CGPoint(x: top.x + (bot.x - top.x) * v, y: top.y + (bot.y - top.y) * v)
            }
            var said: [String] = []
            var moneyLeft = false
            for r in quarters {
                // Skip what a bill already found covers: its own corners would make it look like a second bill.
                if found.contains(where: { $0.contains(at(r.midX, r.midY)) }) || out.contains(where: { $0.quad.contains(at(r.midX, r.midY)) }) { continue }
                guard let piece = part(crop, r) else { continue }
                let (v, e) = read(piece)
                said.append("\(e["model"] ?? "")")
                if let v { seen[v, default: 0] += 1; moneyLeft = true }
            }
            // A value that only repeats a bill found whole across this patch is that bill showing again, not
            // another one (11/4 replay: the $100, found whole, kept its patch of lit table "a pile of $100s").
            let touching = Set(out.filter { $0.quad.covered(by: p.quad) > 0.3 || p.quad.covered(by: $0.quad) > 0.05 }.compactMap(\.value))
            if !seen.isEmpty, Set(seen.keys).isSubset(of: touching) { moneyLeft = false; entry["same_as_found"] = true }
            let inBills = Set(frameSerials.filter { s in out.contains { $0.quad.contains(s.at) } }.map(\.text))
            let serialsHere = frameSerials.filter { p.quad.contains($0.at) && !inBills.contains($0.text) }
            if !serialsHere.isEmpty { moneyLeft = true }
            entry["model"] = said.joined(separator: " | ")
            entry["seen"] = seen.keys.sorted()
            entry["serials"] = Array(Set(serialsHere.map(\.text))).sorted()
            // The model says "100" about a wallet or a patch of table as readily as about a bill (11/4 photos), so
            // a patch counts as bills on top of bills only with a serial number in it, or when the model also says
            // yes, there is paper money here.
            var money = !serialsHere.isEmpty
            if !money, moneyLeft, let ask {
                let a = ask(crop, moneyQuestion)
                entry["money"] = clean(a)
                money = isYes(a)
            }
            log.append(entry)
            if money {
                anyPile = true
                // Said out loud only when three pieces read it: one or two pieces said "$10" in a fan with no $10.
                pileValues += seen.filter { $0.value >= 3 }.map(\.key)
                pileSerials.formUnion(serialsHere.map(\.text))
            }
        }
        // A serial number printed outside every bill found: a bill was missed.
        let placed = Set(frameSerials.filter { s in out.contains { $0.quad.contains(s.at) } }.map(\.text))
        let stray = Set(frameSerials.map(\.text)).subtracting(placed).subtracting(pileSerials)
        if !stray.isEmpty { log.append(["stray_serials": stray.sorted()]) }
        // One bill found twice (two patches, the same serial): keep it once.
        var kept: [Bill] = []
        var used: Set<String> = []
        // Read bills first, so when two finds are one bill (a smooth patch and the rectangle around the same
        // bill), the one that was read is kept.
        for b in out.sorted(by: { ($0.value != nil ? 0 : 1) < ($1.value != nil ? 0 : 1) }) {
            if kept.contains(where: { b.quad.covered(by: $0.quad) > 0.5 || $0.quad.covered(by: b.quad) > 0.5 }) { continue }
            let mine = Set(frameSerials.filter { b.quad.contains($0.at) }.map(\.text))
            if !mine.isEmpty, !mine.isDisjoint(with: used) { continue }
            used.formUnion(mine)
            kept.append(b)
        }
        // One look at the whole frame: how many bills does the model think there are? Its count is a guess (it
        // said "10 bills" for seven), so it is never spoken; it can only stop a total. If it sees more bills than
        // were found, one was missed (11/4 replay: a fan where only the top $100 was found, "That's one $100 bill").
        var modelCount: Int?
        if let ask, !kept.isEmpty, !anyPile {
            let a = ask(image, countQuestion)
            modelCount = number(in: a) ?? wordNumber(a)
            log.append(["model_count": a.map(clean) ?? ""])
        }
        // A smooth patch the model calls money, away from every bill read: glare on a bill that wasn't found.
        let unseen = smoothMoney.contains { q in !kept.contains { q.covered(by: $0.quad) > 0.2 || $0.quad.covered(by: q) > 0.2 } }
        let missed = !stray.isEmpty || unseen || (modelCount.map { $0 > kept.count } ?? false)
        var c = count(kept, moreSeen: missed, pile: anyPile ? pileValues : nil)
        // When bills overlap, the fewest there can be: every one found whole, every distinct serial, every distinct
        // value. Each is a floor on its own, so the largest of them is too (adding them could count a bill twice).
        c.atLeast = max(kept.filter { $0.value != nil }.count, Set(frameSerials.map(\.text)).count, Set(c.values + c.pileValues).count)
        c.size = CGSize(width: image.width, height: image.height)
        return (c, log)
    }

    /// Bill rectangles Vision finds inside one patch (searched in that patch's box only).
    static func rectanglesInside(_ image: CGImage, _ q: Quad) -> [Quad] {
        let xs = q.corners.map(\.x), ys = q.corners.map(\.y)
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let box = CGRect(x: max(0, xs.min()!), y: max(0, ys.min()!), width: 0, height: 0)
            .union(CGRect(x: min(W, xs.max()!), y: min(H, ys.max()!), width: 0, height: 0)).insetBy(dx: -W * 0.02, dy: -H * 0.02)
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        // CGImage cropping counts from the top.
        guard box.width > 16, box.height > 16,
              let sub = image.cropping(to: CGRect(x: box.minX, y: H - box.maxY, width: box.width, height: box.height).integral) else { return [] }
        let rects = rectangles(in: sub).map { Quad(corners: $0.corners.map { CGPoint(x: $0.x + box.minX, y: $0.y + box.minY) }) }
        return bills(from: rects, frameArea: W * H).filter { q.contains($0.center) }
    }

    static func paperMinPixels(_ image: CGImage) -> Int {
        let s = 360 / CGFloat(max(image.width, image.height))
        return max(20, Int(CGFloat(image.width) * s) * Int(CGFloat(image.height) * s) / 300)
    }
}

// MARK: - Memory

/// The last count, so "how many ones?" or "are you sure?" a few seconds later gets the same answer, not a new
/// guess (11/4: five different totals in one minute for the same seven bills).
struct MoneyMemory {
    static let maxAge: TimeInterval = 60
    private(set) var last: LiveMoney.Count?
    private(set) var at = Date.distantPast
    mutating func note(_ c: LiveMoney.Count, at t: Date = Date()) { last = c; at = t }
    func recent(at t: Date = Date()) -> LiveMoney.Count? { t.timeIntervalSince(at) <= Self.maxAge ? last : nil }
    mutating func forget() { last = nil }
}
