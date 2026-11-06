import CoreGraphics
import CoreImage
import CoreML
import Foundation

/// The on-device money detector (v3): a YOLO OBB model finds and boxes every bill (whole bills, fan strips, edge
/// slivers) and reads corner numerals; a small crop classifier looks at each bill's box (colour, portrait, ribbon,
/// inkwell). A bill gets a value only when the numerals and the look agree; anything else is unread. The detector
/// count is the bill count. Port of `rtcam-money-detector/src/v2/decode2.py` with `models/decode_cfg_v3.json`. No UIKit, so tools/money-replay builds it on the Mac.
enum MoneyDetector {
    struct Found {
        var quad: LiveMoney.Quad          // pixels, y up (Core Image's way round), like every Quad in LiveMoney
        var conf: Float
        var value: Int?                   // nil = the numerals and the look did not agree
        var look: (value: Int?, p: Float) // the classifier's best denomination
        var numerals: [Int: Float]
        /// The detector is sure of this bill as one bill: confident (>= sureConf) and no neighbouring box was folded
        /// into it by the strip rule. Any unsure bill makes the count "at least".
        var sure = true
    }
    static let sureConf: Float = 0.5

    /// decode_cfg_v3.json. Two bill boxes are one bill only when they are the same box twice: IoU >= stripIoU, the
    /// same angle within stripDeg and the smaller one's centre inside the larger, or IoU >= hardIoU. Neighbouring fan
    /// strips lie at different angles, so they are kept apart. `solo` > 1 = the look alone never names a bill.
    struct Config {
        var billConf: Float = 0.1, readConf: Float = 0.4, ioaMin: Double = 0.5, featureWeight: Float = 0.8
        var stripIoU: Double = 0.4, stripDeg: Double = 8, hardIoU: Double = 0.7
        var clsConf: Float = 0.6, clsConf100: Float = 0.8, numShare: Float = 0.3, veto: Float = 0.9, solo: Float = 1.01
    }
    static var config = Config()
    static let denoms = [1, 2, 5, 10, 20, 50, 100]
    /// The classifier's class order (folders sorted by name when it was trained).
    static let lookNames = ["d1", "d10", "d100", "d2", "d20", "d5", "d50", "none"]

    final class Models {
        let det: MLModel, cls: MLModel
        let detInput: String, clsInput: String
        let ci = CIContext(options: [.useSoftwareRenderer: false])
        init(det: MLModel, cls: MLModel) {
            self.det = det; self.cls = cls
            detInput = det.modelDescription.inputDescriptionsByName.first { $0.value.type == .image }?.key ?? "image"
            clsInput = cls.modelDescription.inputDescriptionsByName.first { $0.value.type == .image }?.key ?? "image"
        }
    }

    /// The models are built into the app (Matt 11/6: "just put it on there, it's only 10 MB"): the folder
    /// `MoneyModels` in the bundle holds MoneyOBB-v3.mlmodelc and MoneyDenom-v3.mlmodelc, compiled before shipping
    /// (never on the phone), and `money-models.json` with `"version": "money-v3"`. money-replay on the Mac points
    /// MONEY_MODELS at a folder laid out the same way. A folder that doesn't check out (a wrong stamp, an output of
    /// the wrong shape) loads nothing, and Live Cam counts the old way.
    static let modelVersion = "money-v3"
    static let stampName = "money-models.json"
    private static var cached: Models??
    private static let cacheLock = NSLock()
    static var models: Models? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = cached { return c }
        let m = load(from: searchFolders()); cached = .some(m); return m
    }
    /// Look for the models again on the next money question (tests).
    static func reload() { cacheLock.lock(); cached = nil; cacheLock.unlock() }

    static func searchFolders() -> [URL] {
        var dirs: [URL] = []
        if let d = ProcessInfo.processInfo.environment["MONEY_MODELS"] { dirs.append(URL(fileURLWithPath: d)) }
        if let b = Bundle.main.url(forResource: "MoneyModels", withExtension: nil) { dirs.append(b) }
        return dirs
    }

    /// The first folder whose stamp, both compiled models and both outputs check out.
    static func load(from dirs: [URL]) -> Models? {
        let fm = FileManager.default
        let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndNeuralEngine
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(stampName)),
                  let stamp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  stamp["version"] as? String == modelVersion else { continue }
            let d = dir.appendingPathComponent("MoneyOBB-v3.mlmodelc"), c = dir.appendingPathComponent("MoneyDenom-v3.mlmodelc")
            guard fm.fileExists(atPath: d.path), fm.fileExists(atPath: c.path),
                  let det = try? MLModel(contentsOf: d, configuration: cfg), let cls = try? MLModel(contentsOf: c, configuration: cfg),
                  validDetector(det.modelDescription), validClassifier(cls.modelDescription) else { continue }
            return Models(det: det, cls: cls)
        }
        return nil
    }
    /// The detector answers one [1, 300, 7] (end-to-end) or [1, 20, 8400] (standard head) array.
    static func validShape(_ shape: [Int]) -> Bool { shape == [1, 300, 7] || shape == [1, 20, 8400] }
    static func validDetector(_ d: MLModelDescription) -> Bool {
        guard d.inputDescriptionsByName.values.contains(where: { $0.type == .image }),
              let o = d.outputDescriptionsByName.values.first(where: { $0.type == .multiArray }),
              let shape = o.multiArrayConstraint?.shape.map(\.intValue) else { return false }
        return validShape(shape)
    }
    static func validClassifier(_ d: MLModelDescription) -> Bool {
        d.inputDescriptionsByName.values.contains { $0.type == .image }
            && d.outputDescriptionsByName.values.contains { $0.type == .dictionary || ($0.type == .multiArray && ($0.multiArrayConstraint?.shape.last?.intValue ?? 0) == lookNames.count) }
    }

    // MARK: - Geometry (pure, image pixels y down)

    typealias Poly = [CGPoint]
    static func area(_ p: Poly) -> Double {
        guard p.count > 2 else { return 0 }
        var s = 0.0
        for i in p.indices { let a = p[i], b = p[(i + 1) % p.count]; s += Double(a.x * b.y - b.x * a.y) }
        return abs(s) / 2
    }
    /// Convex polygon intersection (Sutherland-Hodgman); both are convex quads here.
    static func intersection(_ subject: Poly, _ clip: Poly) -> Poly {
        var out = subject
        let ccw = signedArea(clip) > 0
        for i in clip.indices {
            guard !out.isEmpty else { break }
            let a = clip[i], b = clip[(i + 1) % clip.count]
            func inside(_ p: CGPoint) -> Bool { let c = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x); return ccw ? c >= 0 : c <= 0 }
            func cross(_ p: CGPoint, _ q: CGPoint) -> CGPoint {
                let d1 = CGPoint(x: q.x - p.x, y: q.y - p.y), d2 = CGPoint(x: b.x - a.x, y: b.y - a.y)
                let den = d1.x * d2.y - d1.y * d2.x
                if abs(den) < 1e-9 { return q }
                let t = ((a.x - p.x) * d2.y - (a.y - p.y) * d2.x) / den
                return CGPoint(x: p.x + t * d1.x, y: p.y + t * d1.y)
            }
            let input = out; out = []
            for j in input.indices {
                let p = input[j], q = input[(j + 1) % input.count]
                if inside(q) { if !inside(p) { out.append(cross(p, q)) }; out.append(q) } else if inside(p) { out.append(cross(p, q)) }
            }
        }
        return out
    }
    static func signedArea(_ p: Poly) -> Double {
        var s = 0.0
        for i in p.indices { let a = p[i], b = p[(i + 1) % p.count]; s += Double(a.x * b.y - b.x * a.y) }
        return s / 2
    }
    static func iou(_ a: Poly, _ b: Poly) -> Double {
        let i = area(intersection(a, b)); return i / max(area(a) + area(b) - i, 1e-9)
    }
    /// cx, cy, w, h, angle (radians) -> 4 corners, the same way round as Ultralytics' xywhr2xyxyxyxy.
    static func corners(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Poly {
        let c = cos(r), s = sin(r)
        let v1 = CGPoint(x: w / 2 * c, y: w / 2 * s), v2 = CGPoint(x: -h / 2 * s, y: h / 2 * c)
        return [CGPoint(x: cx + v1.x + v2.x, y: cy + v1.y + v2.y), CGPoint(x: cx + v1.x - v2.x, y: cy + v1.y - v2.y),
                CGPoint(x: cx - v1.x - v2.x, y: cy - v1.y - v2.y), CGPoint(x: cx - v1.x + v2.x, y: cy - v1.y + v2.y)]
    }

    struct Det { var cls: Int; var conf: Float; var poly: Poly; var box: (cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat) }

    // MARK: - The decode (pure; decode2.stage1 + finish)

    /// A box's long-side direction in degrees, 0 ..< 180.
    static func angle(_ b: (cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat)) -> Double {
        var a = Double(b.r) * 180 / .pi + (b.w < b.h ? 90 : 0)
        a = a.truncatingRemainder(dividingBy: 180); return a < 0 ? a + 180 : a
    }
    static func contains(_ p: Poly, _ q: CGPoint) -> Bool {
        var sign: CGFloat = 0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count], c = (b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x)
            if c != 0 { if sign == 0 { sign = c } else if (c > 0) != (sign > 0) { return false } }
        }
        return true
    }
    /// True when `d` is a second box on a bill already kept as `k` (strip-aware, see Config).
    static func sameBill(_ d: Det, _ k: Det, _ c: Config) -> Bool {
        let o = iou(d.poly, k.poly)
        if o >= c.hardIoU { return true }
        guard o >= c.stripIoU else { return false }
        var da = abs(angle(d.box) - angle(k.box)); da = min(da, 180 - da)
        let (small, big) = area(d.poly) <= area(k.poly) ? (d, k) : (k, d)
        return da <= c.stripDeg && contains(big.poly, CGPoint(x: small.box.cx, y: small.box.cy))
    }

    /// Bills (strip-aware suppression) with the numeral votes assigned to each, as decode2.stage1.
    static func bills(_ dets: [Det], _ c: Config) -> [(det: Det, votes: [Int: Float])] { billsMerged(dets, c).map { ($0.det, $0.votes) } }
    /// As `bills`, plus whether a second bill box was folded into each kept bill below the hard IoU (a possible strip).
    static func billsMerged(_ dets: [Det], _ c: Config) -> [(det: Det, votes: [Int: Float], merged: Bool)] {
        var keep: [(det: Det, votes: [Int: Float], merged: Bool)] = []
        for d in dets.filter({ $0.cls == 0 && $0.conf >= c.billConf }).sorted(by: { $0.conf > $1.conf }) {
            if let i = keep.firstIndex(where: { sameBill(d, $0.det, c) }) {
                if iou(d.poly, keep[i].det.poly) < c.hardIoU && d.conf >= sureConf { keep[i].merged = true }
                continue
            }
            keep.append((d, [:], false))
        }
        for d in dets where d.cls != 0 && d.conf >= c.readConf {
            let val = denoms[(d.cls - 1) % 7], w = d.conf * (d.cls <= 7 ? 1 : c.featureWeight), a = max(area(d.poly), 1e-9)
            var best: (ioa: Double, i: Int)?
            for (i, k) in keep.enumerated() {
                let ioa = area(intersection(d.poly, k.det.poly)) / a
                guard ioa >= c.ioaMin else { continue }
                if let b = best {
                    let smaller = area(k.det.poly) < area(keep[b.i].det.poly)
                    if ioa > b.ioa + 0.05 || (abs(ioa - b.ioa) <= 0.05 && smaller) { best = (ioa, i) }
                } else { best = (ioa, i) }
            }
            if let b = best { keep[b.i].votes[val, default: 0] += w }
        }
        return keep
    }

    /// One bill's value from its numeral votes and the classifier's probabilities, as decode2.finish.
    /// Returns nil for the bill itself when the classifier vetoes it as not money.
    static func value(votes: [Int: Float], probs: [String: Float], _ c: Config) -> (keep: Bool, value: Int?, look: (Int?, Float)) {
        if probs["none", default: 0] >= c.veto { return (false, nil, (nil, 0)) }
        let tot = votes.values.reduce(0, +)
        guard let top = probs.filter({ $0.key != "none" }).max(by: { $0.value < $1.value }), let d = Int(top.key.dropFirst()) else {
            return (true, nil, (nil, 0))
        }
        let need = d == 100 ? c.clsConf100 : c.clsConf
        let share = tot > 0 ? votes[d, default: 0] / tot : 0
        if top.value >= need && share >= c.numShare && tot > 0 { return (true, d, (d, top.value)) }
        if tot == 0 && top.value >= c.solo { return (true, d, (d, top.value)) }
        return (true, nil, (d, top.value))
    }

    // MARK: - Running the models

    /// Every bill in the frame, or nil when the models aren't there (the old patch/rectangle search runs instead).
    /// What one look found: the bills, and whether anything in the frame still suggests money when no bill was
    /// found (a weak or vetoed bill box, a numeral, or the classifier on the whole frame), so "no bills" is never
    /// said about a frame that may hold money.
    /// `droppedReflection`: a box was left out as a bill's mirror image, so a real bill may be missing too: the
    /// count is then a floor, never a total.
    struct Detection { var found: [Found]; var maybeMoney: Bool; var droppedReflection = false }

    /// Debug trace (MONEY_TRACE=1 on the Mac replay, or a test's own sink).
    nonisolated(unsafe) static var traceSink: ((String) -> Void)?
    static var traceOn: Bool { traceSink != nil || ProcessInfo.processInfo.environment["MONEY_TRACE"] != nil }
    static func trace(_ s: String) {
        if let traceSink { traceSink(s) } else { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    }

    static func detect(_ image: CGImage) -> Detection? {
        guard let m = models else { return nil }
        return detect(image, models: m)
    }

    static func detect(_ image: CGImage, models m: Models) -> Detection? {
        autoreleasepool { detectOnce(image, m) }   // Core ML, Core Image and Vision buffers go when the look ends
    }

    private static func detectOnce(_ image: CGImage, _ m: Models) -> Detection? {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let side: CGFloat = 640, scale = min(side / W, side / H)
        let padX = (side - W * scale) / 2, padY = (side - H * scale) / 2
        let src = CIImage(cgImage: image)
        // Letterbox the way the model was trained and checked (OpenCV area resize, grey 114 pad, sRGB): Core Graphics
        // with high-quality interpolation averages the pixels it shrinks. A plain Core Image scale samples them,
        // and the aliasing cost whole fan strips (11/5 replay: 8006 counted 6 for 7).
        guard let buf = letterbox(image, side: Int(side), scale: scale, padX: padX, padY: padY),
              let fp = try? MLDictionaryFeatureProvider(dictionary: [m.detInput: MLFeatureValue(pixelBuffer: buf)]),
              let out = try? m.det.prediction(from: fp),
              let name = out.featureNames.first, let a = out.featureValue(for: name)?.multiArrayValue,
              validShape(a.shape.map(\.intValue))
        else { return nil }   // a failed look is no answer, never "no bills": the old way counts this frame instead
        // Two export layouts: the end-to-end head [1, 300, 7] (cx, cy, w, h, conf, class, angle per row), or the
        // standard head [1, 20, 8400] (cx, cy, w, h, 15 class scores, angle per column).
        let endToEnd = a.shape[2].intValue == 7
        let n = endToEnd ? a.shape[1].intValue : a.shape[2].intValue
        let rs = endToEnd ? a.strides[2].intValue : a.strides[1].intValue, cs = endToEnd ? a.strides[1].intValue : a.strides[2].intValue
        func v(_ row: Int, _ i: Int) -> Float {
            let k = row * rs + i * cs
            switch a.dataType {
            case .float16: return Float(a.dataPointer.assumingMemoryBound(to: Float16.self)[k])
            case .double: return Float(a.dataPointer.assumingMemoryBound(to: Double.self)[k])
            default: return a.dataPointer.assumingMemoryBound(to: Float.self)[k]
            }
        }
        // Each column's best class, conf >= 0.05, then per-class rotated NMS at 0.7 (the export has no NMS).
        var raw: [Det] = []
        for i in 0 ..< n {
            var best = 0, bc: Float = 0
            if endToEnd { bc = v(4, i); best = Int(v(5, i).rounded()) } else {
                for c in 0 ..< 15 { let s = v(4 + c, i); if s > bc { bc = s; best = c } }
            }
            guard bc >= 0.05, (0 ..< 15).contains(best) else { continue }
            // input pixels (y down) -> image pixels (y down)
            let cx = (CGFloat(v(0, i)) - padX) / scale, cy = (CGFloat(v(1, i)) - (side - padY - H * scale)) / scale
            let w = CGFloat(v(2, i)) / scale, h = CGFloat(v(3, i)) / scale, r = CGFloat(v(endToEnd ? 6 : 19, i))
            raw.append(Det(cls: best, conf: bc, poly: corners(cx, cy, w, h, r), box: (cx, cy, w, h, r)))
        }
        // Per-class rotated NMS at 0.7 for both layouts: the trainer's own decode (Ultralytics predict) runs it on the
        // end-to-end head too, and without it the Core ML output keeps near-duplicate bill boxes (8006: 12 vs 7).
        var dets: [Det] = []
        for c in 0 ..< 15 {
            var kept: [Det] = []
            for d in raw.filter({ $0.cls == c }).sorted(by: { $0.conf > $1.conf }) where kept.count < 300 {
                if kept.allSatisfy({ iou(d.poly, $0.poly) < 0.7 }) { kept.append(d) }
            }
            dets += kept
        }
        let c = config
        var found: [Found] = []
        var kept: [Det] = []
        var dropped = false
        for (d, votes, merged) in billsMerged(dets, c) {
            let probs = look(src, d.box, H, m)
            let (keep, val, lk) = value(votes: votes, probs: probs, c)
            guard keep else { continue }
            // A bill's mirror image on a glossy table (CC0 xh_18: one $1 counted as three) is not a bill.
            // Where a kept bill's mirror image would lie: the pixels decide. A clear mirror is dropped (and the count
            // becomes a floor); a clear real bill (two $20s edge to edge) is kept as it is; anything between is kept
            // but never named or counted as sure.
            var isMirror = false, maybeMirror = false
            for k in kept where mirrorGeometry(k, d) {
                switch mirrorVerdict(k, d, in: src, H) {
                case .mirror: isMirror = true
                case .unsure: maybeMirror = true
                case .real: break
                }
                if isMirror { break }
            }
            if isMirror { dropped = true; continue }
            if traceOn { for k in kept { trace("MONEY_TRACE refl? \(reflectionTrace(k, d, src, H))") } }
            kept.append(d)
            let q = LiveMoney.Quad(corners: d.poly.map { CGPoint(x: $0.x, y: H - $0.y) })
            // Sure of it as a bill only when the classifier also sees money in it (phone run 11/6, CC0 xh_18: a
            // patch of brick wall boxed at 0.5+ made "at least 2" of one $1).
            let looksLikeMoney = probs["none", default: 1] < 0.5 && (lk.1 >= 0.5)
            if traceOn { trace(String(format: "MONEY_TRACE bill conf=%.2f none=%.2f top=%@ %.2f", d.conf, probs["none", default: -1], "\(lk.0 ?? 0)", lk.1)) }
            found.append(Found(quad: q, conf: d.conf, value: maybeMirror ? nil : val, look: lk, numerals: votes,
                               sure: d.conf >= sureConf && !merged && !maybeMirror && looksLikeMoney))
        }
        var maybe = !found.isEmpty
        if !maybe {
            maybe = dets.contains { ($0.cls == 0 && $0.conf >= 0.1) || ($0.cls != 0 && $0.conf >= 0.25) }
            if !maybe {
                let all = look(src, (W / 2, H / 2, W, H, 0), H, m)
                if let top = all.max(by: { $0.value < $1.value }), top.key != "none", top.value >= 0.5 { maybe = true }
            }
        }
        if traceOn {
            let b = dets.filter { $0.cls == 0 && $0.conf >= c.billConf }
            trace("MONEY_TRACE raw=\(raw.count) nms=\(dets.count) bills>=conf=\(b.count) kept=\(bills(dets, c).count) found=\(found.count) confs=\(b.map { String(format: "%.2f", $0.conf) })")
        }
        return Detection(found: found, maybeMoney: maybe, droppedReflection: dropped)
    }

    /// `b` is the mirror image of `a`: about the same size and angle, lying against `a`'s long side, and its crop
    /// matches `a`'s crop flipped (a mirror) clearly better than turned (a real bill upside down).
    static func isReflection(of a: Det, _ b: Det, in src: CIImage, _ H: CGFloat) -> Bool {
        mirrorGeometry(a, b) && mirrorVerdict(a, b, in: src, H) == .mirror
    }

    enum MirrorVerdict { case mirror, real, unsure }
    static func mirrorVerdict(_ a: Det, _ b: Det, in src: CIImage, _ H: CGFloat) -> MirrorVerdict {
        guard let ga = grey(src, a.box, H), let gb = grey(src, b.box, H) else { return .unsure }
        return mirrorVerdict(ga, gb)
    }
    /// Pure: a clear mirror (see mirrorScore), a clear real bill (it matches turned or as it is clearly better than
    /// flipped), or can't tell.
    static func mirrorVerdict(_ a: [Float], _ b: [Float]) -> MirrorVerdict {
        if mirrorScore(a, b) { return .mirror }
        let (mirror, turn) = mirrorScores(a, b)
        return turn > 0.5 && turn > mirror + 0.1 ? .real : .unsure
    }

    /// Pure: `b` lies where `a`'s mirror image would: about the same size and angle, against `a`'s long side
    /// (centres a short side apart, across the long axis, barely shifted along it).
    static func mirrorGeometry(_ a: Det, _ b: Det) -> Bool {
        let la = max(a.box.w, a.box.h), sa = min(a.box.w, a.box.h), lb = max(b.box.w, b.box.h), sb = min(b.box.w, b.box.h)
        guard lb / la > 0.75, lb / la < 1.33, sb / sa > 0.6, sb / sa < 1.6 else { return false }
        var da = abs(angle(a.box) - angle(b.box)); da = min(da, 180 - da)
        guard da <= 8 else { return false }
        let ar = angle(a.box) * .pi / 180, dx = b.box.cx - a.box.cx, dy = b.box.cy - a.box.cy
        let along = abs(dx * CGFloat(cos(ar)) + dy * CGFloat(sin(ar))), across = abs(-dx * CGFloat(sin(ar)) + dy * CGFloat(cos(ar)))
        return along < 0.15 * la && across > 0.6 * sa && across < 1.6 * sa
    }

    static func reflectionTrace(_ a: Det, _ b: Det, _ src: CIImage, _ H: CGFloat) -> String {
        let la = max(a.box.w, a.box.h), sa = min(a.box.w, a.box.h)
        let ar = angle(a.box) * .pi / 180, dx = b.box.cx - a.box.cx, dy = b.box.cy - a.box.cy
        let along = abs(dx * CGFloat(cos(ar)) + dy * CGFloat(sin(ar))) / la, across = abs(-dx * CGFloat(sin(ar)) + dy * CGFloat(cos(ar))) / sa
        var da = abs(angle(a.box) - angle(b.box)); da = min(da, 180 - da)
        var sc = ""
        if let ga = grey(src, a.box, H), let gb = grey(src, b.box, H) { sc = "\(mirrorScores(ga, gb))" }
        return String(format: "a=(%.0f,%.0f %.0fx%.0f) b=(%.0f,%.0f %.0fx%.0f) da=%.1f along=%.2f across=%.2f ", a.box.cx, a.box.cy, a.box.w, a.box.h, b.box.cx, b.box.cy, b.box.w, b.box.h, da, along, across) + sc
    }

    /// Small grey crop of a box, long side across (48 x 20), as floats.
    static func grey(_ src: CIImage, _ b: (cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat), _ H: CGFloat) -> [Float]? {
        var (w, h, r) = (b.w, b.h, b.r)
        if w < h { swap(&w, &h); r += .pi / 2 }
        let u = CGPoint(x: cos(r), y: sin(r)), v = CGPoint(x: -sin(r), y: cos(r))
        func p(_ su: CGFloat, _ sv: CGFloat) -> CIVector { CIVector(x: b.cx + u.x * su * w / 2 + v.x * sv * h / 2, y: H - (b.cy + u.y * su * w / 2 + v.y * sv * h / 2)) }
        guard let f = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        f.setValue(src.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(p(-1, -1), forKey: "inputTopLeft"); f.setValue(p(1, -1), forKey: "inputTopRight")
        f.setValue(p(1, 1), forKey: "inputBottomRight"); f.setValue(p(-1, 1), forKey: "inputBottomLeft")
        guard var c = f.outputImage, c.extent.width > 1, c.extent.height > 1 else { return nil }
        let gw = 48, gh = 20
        c = c.transformed(by: CGAffineTransform(translationX: -c.extent.minX, y: -c.extent.minY))
        c = c.transformed(by: CGAffineTransform(scaleX: CGFloat(gw) / c.extent.width, y: CGFloat(gh) / c.extent.height))
        var px = [UInt8](repeating: 0, count: gw * gh * 4)
        greyContext.render(c, toBitmap: &px, rowBytes: gw * 4, bounds: CGRect(x: 0, y: 0, width: gw, height: gh), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (0 ..< gw * gh).map { Float(px[$0 * 4]) * 0.3 + Float(px[$0 * 4 + 1]) * 0.59 + Float(px[$0 * 4 + 2]) * 0.11 }
    }
    private static let greyContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Pure: a 48 x 20 grey crop `b` is a mirror of `a` (flipped across either axis matches better than any turn).
    static func mirrorScore(_ a: [Float], _ b: [Float], w: Int = 48, h: Int = 20) -> Bool {
        guard a.count == w * h, b.count == w * h else { return false }
        func flipV(_ x: [Float]) -> [Float] { (0 ..< h).flatMap { r in x[(h - 1 - r) * w ..< (h - r) * w] } }
        func flipH(_ x: [Float]) -> [Float] { (0 ..< h).flatMap { r in x[r * w ..< (r + 1) * w].reversed() } }
        func corr(_ x: [Float], _ y: [Float]) -> Float {
            let mx = x.reduce(0, +) / Float(x.count), my = y.reduce(0, +) / Float(y.count)
            var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
            for i in x.indices { let dx = x[i] - mx, dy = y[i] - my; sxy += dx * dy; sxx += dx * dx; syy += dy * dy }
            return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
        }
        let (mirror, turn) = mirrorScores(a, b, w: w, h: h)
        guard mirror > 0.5 else { return false }
        // A reflection is also fainter than the bill. A $1 looks much the same turned, so a faint copy needs only
        // a small mirror margin (xh_18: mirror 0.61, turned 0.51).
        func spread(_ x: [Float]) -> Float { let m = x.reduce(0, +) / Float(x.count); return (x.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(x.count)).squareRoot() }
        return mirror > turn + 0.15 || (mirror > turn + 0.05 && spread(b) < 0.85 * spread(a))
    }
    static func mirrorScores(_ a: [Float], _ b: [Float], w: Int = 48, h: Int = 20) -> (mirror: Float, turn: Float) {
        guard a.count == w * h, b.count == w * h else { return (0, 0) }
        func flipV(_ x: [Float]) -> [Float] { (0 ..< h).flatMap { r in x[(h - 1 - r) * w ..< (h - r) * w] } }
        func flipH(_ x: [Float]) -> [Float] { (0 ..< h).flatMap { r in x[r * w ..< (r + 1) * w].reversed() } }
        func corr(_ x: [Float], _ y: [Float]) -> Float {
            let mx = x.reduce(0, +) / Float(x.count), my = y.reduce(0, +) / Float(y.count)
            var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
            for i in x.indices { let dx = x[i] - mx, dy = y[i] - my; sxy += dx * dy; sxx += dx * dx; syy += dy * dy }
            return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
        }
        return (max(corr(a, flipV(b)), corr(a, flipH(b))), max(corr(a, b), corr(a, flipH(flipV(b)))))
    }

    /// The classifier on one bill's box, straightened long side across, padded like training, 224 x 224.
    static func look(_ src: CIImage, _ b: (cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat), _ H: CGFloat, _ m: Models) -> [String: Float] {
        var (w, h, r) = (b.w, b.h, b.r)
        if w < h { swap(&w, &h); r += .pi / 2 }
        let W2 = w * 1.06, H2 = h * 1.06 + 0.04 * w
        let u = CGPoint(x: cos(r), y: sin(r)), vv = CGPoint(x: -sin(r), y: cos(r))
        func p(_ su: CGFloat, _ sv: CGFloat) -> CIVector {   // y down -> Core Image y up
            CIVector(x: b.cx + u.x * su * W2 / 2 + vv.x * sv * H2 / 2, y: H - (b.cy + u.y * su * W2 / 2 + vv.y * sv * H2 / 2))
        }
        guard let f = CIFilter(name: "CIPerspectiveCorrection") else { return [:] }
        f.setValue(src.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(p(-1, -1), forKey: "inputTopLeft"); f.setValue(p(1, -1), forKey: "inputTopRight")
        f.setValue(p(1, 1), forKey: "inputBottomRight"); f.setValue(p(-1, 1), forKey: "inputBottomLeft")
        guard var crop = f.outputImage, crop.extent.width > 1, crop.extent.height > 1 else { return [:] }
        crop = crop.transformed(by: CGAffineTransform(translationX: -crop.extent.minX, y: -crop.extent.minY))
        crop = crop.transformed(by: CGAffineTransform(scaleX: 224 / crop.extent.width, y: 224 / crop.extent.height))
        guard let buf = pixelBuffer(224, 224, m.cls), render(crop, into: buf, m) != nil,
              let fp = try? MLDictionaryFeatureProvider(dictionary: [m.clsInput: MLFeatureValue(pixelBuffer: buf)]),
              let out = try? m.cls.prediction(from: fp) else { return [:] }
        // The Core ML classifier answers a label -> probability dictionary ("classLabel_probs"); an array output
        // (other exports) is read in the training class order.
        for name in out.featureNames {
            if let dict = out.featureValue(for: name)?.dictionaryValue, !dict.isEmpty {
                var d: [String: Float] = [:]
                for (k, v) in dict { if let s = k as? String { d[s] = v.floatValue } }
                return d
            }
            if let a = out.featureValue(for: name)?.multiArrayValue, a.count == lookNames.count {
                var d: [String: Float] = [:]
                for (i, k) in lookNames.enumerated() { d[k] = a[i].floatValue }
                return d
            }
        }
        return [:]
    }

    private static func letterbox(_ image: CGImage, side: Int, scale: CGFloat, padX: CGFloat, padY: CGFloat) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferCGImageCompatibilityKey as String: true,
                                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out)
        guard let out else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(out), width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(out), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setFillColor(red: 114 / 255, green: 114 / 255, blue: 114 / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: padX, y: padY, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
        return out
    }

    private static func pixelBuffer(_ w: Int, _ h: Int, _ model: MLModel) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out)
        return out
    }
    @discardableResult
    private static func render(_ img: CIImage, into buf: CVPixelBuffer, _ m: Models) -> CVPixelBuffer? {
        m.ci.render(img, to: buf, bounds: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buf), height: CVPixelBufferGetHeight(buf)),
                    colorSpace: CGColorSpaceCreateDeviceRGB())
        return buf
    }
}
