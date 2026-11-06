// Money replay: runs Live Cam's money counting (LiveMoney.swift, the same file the app builds) and its model
// (LiveVisionEngine.swift, the same llama.cpp code, macOS slice) on frames pulled from a video, and prints what
// Live Cam would say for each frame and each burst.
//
// Matt's test videos film the phone screen with a second phone, so each frame is first cut down to the phone
// (Vision's foreground mask), which keeps the real bills behind the phone out of the count.
//
// usage: money-replay <level> <truth e.g. 100,20,5,1,1,1,1> <burst> frame.jpg ...
//   burst: most frames per answer (the app takes up to 3, more only while bills are unread)
import CoreImage
import Foundation
import ImageIO
import Vision

let args = CommandLine.arguments
guard args.count > 4, let level = ModelLevel(rawValue: args[1]) ?? (args[1] == "none" ? .balanced : nil), let burst = Int(args[3]) else {
    print("usage: money-replay <sharp|clear|balanced|quick|none> <truth> <burst> frames..."); exit(2)
}
let truth = args[2].split(separator: ",").compactMap { Int($0) }.sorted()
let paths = Array(args.dropFirst(4))
let engine = args[1] == "none" ? nil : try? LiveVisionEngine(level: level)
let ctx = CIContext()

func load(_ p: String) -> CGImage? {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(s, 0, nil)
}

/// The phone in the shot, everything else black.
func phoneOnly(_ img: CGImage) -> CGImage {
    let rq = VNGenerateForegroundInstanceMaskRequest()
    let h = VNImageRequestHandler(cgImage: img)
    guard (try? h.perform([rq])) != nil, let r = rq.results?.first,
          let m = try? r.generateMaskedImage(ofInstances: r.allInstances, from: h, croppedToInstancesExtent: true) else { return img }
    let ci = CIImage(cvPixelBuffer: m)
    return ctx.createCGImage(ci, from: ci.extent) ?? img
}

let ask: LiveMoney.Ask? = engine.map { e in
    { img, q in e.respond(system: LiveMoney.modelSystem, question: q, image: img, longSide: LiveMoney.modelLongSide, maxTokens: 4)?.text }
}

/// How many of the values it read are right (multiset overlap with the truth).
func readRight(_ c: LiveMoney.Count) -> Int {
    var left = truth
    var n = 0
    for v in c.values { if let i = left.firstIndex(of: v) { left.remove(at: i); n += 1 } }
    return n
}

/// Honest: a total only when it is right; otherwise no value that isn't there, no count that is wrong unless
/// it says the count may be off.
func honest(_ c: LiveMoney.Count) -> Bool {
    if c.sure { return c.values.sorted() == truth }
    if readRight(c) != c.values.count { return false }
    if !Set(c.pileValues).isSubset(of: Set(truth)) { return false }
    if c.doubts.contains(.overlapping) { return c.atLeast <= truth.count }
    // "At least N bills" (detector path, count not sure): honest when the floor holds.
    if c.doubts.contains(.countUnsure) { return max(c.atLeast, c.values.count) <= truth.count }
    if c.doubts.contains(.none) { return true }
    let hedged = !Set(c.doubts).isDisjoint(with: [.cutOff, .moreThanFound, .frames])
    return hedged ? c.bills.count <= truth.count : c.bills.count == truth.count
}

func describe(_ e: [String: Any]) -> String {
    if let st = e["stray_serials"] { return "STRAY\(st)" }
    if let mc = e["model_count"] { return "count:\(mc)" }
    if e["skipped"] != nil { return "skip(detail \(e["detail"]!))" }
    if e["pile"] != nil { return "PILE seen\(e["seen"]!) serials\(e["serials"] ?? []) det\(e["detail"] ?? 0) money:\(e["money"] ?? "-")\(e["same_as_found"] != nil ? " =found" : "")" }
    return "\(e["value"] ?? 0)[m \(e["model"] ?? "")\((e["cut"] as? Bool ?? false) ? " cut" : "")\((e["word"] as? Int ?? 0) > 0 ? " w\(e["word"]!)" : "")\((e["numeral"] as? Int ?? 0) > 0 ? " n\(e["numeral"]!)" : "")]"
}

/// MONEY_DEBUG: every pale patch, outlined (green = bill-shaped), to /tmp/money-replay-overlay.jpg.
func debugDump(_ phone: CGImage) {
    let blobs = LiveMoney.paperBlobs(in: phone)
    for (k, bl) in blobs.enumerated() {
        print(String(format: "    blob %d c(%.0f,%.0f) elong %.2f fill %.2f px %d %@%@", k, bl.quad.center.x, bl.quad.center.y, bl.quad.elongation, bl.fill, bl.pixels, bl.billLike ? "BILL" : "-", bl.atEdge ? " edge" : ""))
    }
    guard let g = CGContext(data: nil, width: phone.width, height: phone.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
    g.draw(phone, in: CGRect(x: 0, y: 0, width: phone.width, height: phone.height))
    g.setLineWidth(5)
    for bl in blobs {
        g.setStrokeColor(bl.billLike ? CGColor(red: 0, green: 1, blue: 0, alpha: 1) : CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        g.addLines(between: bl.quad.corners + [bl.quad.corners[0]]); g.strokePath()
    }
    if let o = g.makeImage() {
        try? ctx.writeJPEGRepresentation(of: CIImage(cgImage: o), to: URL(fileURLWithPath: "/tmp/money-replay-overlay.jpg"), colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}

var frames = 0, fRight = 0, fHonest = 0
var answers = 0, aRight = 0, aHonest = 0
var foundSum = 0, readRightSum = 0
var current = "", started = Date()
var i = 0
while i < paths.count {
    let group = Array(paths[i ..< min(paths.count, i + burst)])
    i += burst
    // The app's burst: one frame, more only while some bills are unread (LiveMoney.countBurst).
    var k = 0
    let t0 = Date()
    let a = LiveMoney.countBurst(maxFrames: burst, frame: { () -> CGImage? in
        guard k < group.count, let img = load(group[k]) else { return nil }
        current = URL(fileURLWithPath: group[k]).lastPathComponent
        k += 1
        let phone = ProcessInfo.processInfo.environment["NO_MASK"] != nil ? img : phoneOnly(img)   // NO_MASK: a real camera photo, not a filmed screen
        if ProcessInfo.processInfo.environment["MONEY_DEBUG"] != nil { debugDump(phone) }
        started = Date()
        return phone
    }, ask: ask, onLook: { c, log in
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        frames += 1
        foundSum += c.bills.count; readRightSum += readRight(c)
        if c.sure && c.values.sorted() == truth { fRight += 1 }
        if honest(c) { fHonest += 1 }
        let verdict = c.sure ? (c.values.sorted() == truth ? "RIGHT" : "WRONG") : (honest(c) ? "UNSURE-honest" : "UNSURE-FALSE-CLAIM")
        print("  \(current) \(ms)ms \(verdict) found=\(c.bills.count)/\(truth.count) readRight=\(readRight(c)) doubts=\(c.doubts.map(\.rawValue)) :: \(log.map(describe).joined(separator: " "))")
    })
    answers += 1
    if a.sure && a.values.sorted() == truth { aRight += 1 }
    if honest(a) { aHonest += 1 }
    let v = a.sure ? (a.values.sorted() == truth ? "RIGHT" : "WRONG") : (honest(a) ? "UNSURE-honest" : "UNSURE-FALSE-CLAIM")
    print("ANSWER \(v) (\(k) frame\(k == 1 ? "" : "s"), \(Int(Date().timeIntervalSince(t0) * 1000)) ms): \(LiveMoney.sentence(a))")
}
print("FRAMES \(frames): right total \(fRight), honest \(fHonest), found avg \(String(format: "%.1f", Double(foundSum) / Double(max(1, frames))))/\(truth.count), read right avg \(String(format: "%.1f", Double(readRightSum) / Double(max(1, frames))))")
print("ANSWERS \(answers): right total \(aRight), honest \(aHonest), wrong-or-false \(answers - aHonest)")
fflush(stdout)
_exit(0)   // llama/Metal teardown at exit aborts on macOS; nothing is left to save
