import CoreGraphics
import CoreImage
import CoreML
#if canImport(CryptoKit)
import CryptoKit
#endif
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

    /// The models are NOT in the app download (review.md: no change may add MB to the app download; models come
    /// only with a download the user tapped). They are a `money` folder inside a vision model pack the user already
    /// downloaded (Application Support/VisionModels/<level>/money/), or, for money-replay on the Mac, the folder named
    /// by MONEY_MODELS. The folder holds MoneyOBB-v3.mlmodelc and MoneyDenom-v3.mlmodelc, compiled before shipping
    /// (never compiled on the phone), and `money-models.json` with `"version": "money-v3"`. A folder that doesn't
    /// check out (missing, a wrong stamp, an output of the wrong shape) loads nothing, and Live Cam counts the old way.
    static let modelVersion = "money-v3"
    static let stampName = "money-models.json"
    private static var cached: Models??
    private static let cacheLock = NSLock()
    static var models: Models? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = cached { return c }
        let m = load(from: searchFolders()); cached = .some(m); return m
    }
    /// Called when a vision model pack finishes installing or is deleted: look again on the next money question.
    static func reload() { cacheLock.lock(); cached = nil; cacheLock.unlock() }

    static func searchFolders() -> [URL] {
        var dirs: [URL] = []
        if let d = ProcessInfo.processInfo.environment["MONEY_MODELS"] { dirs.append(URL(fileURLWithPath: d)) }
        if let own = MoneyPack.installedFolder { dirs.append(own) }
        if let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            let packs = support.appendingPathComponent("VisionModels", isDirectory: true)
            for p in ((try? FileManager.default.contentsOfDirectory(at: packs, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path }) {
                dirs.append(p.appendingPathComponent("money", isDirectory: true))
            }
        }
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
    static func detect(_ image: CGImage) -> [Found]? {
        guard let m = models else { return nil }
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
        for (d, votes, merged) in billsMerged(dets, c) {
            let probs = look(src, d.box, H, m)
            let (keep, val, lk) = value(votes: votes, probs: probs, c)
            guard keep else { continue }
            let q = LiveMoney.Quad(corners: d.poly.map { CGPoint(x: $0.x, y: H - $0.y) })
            found.append(Found(quad: q, conf: d.conf, value: val, look: lk, numerals: votes, sure: d.conf >= sureConf && !merged))
        }
        if ProcessInfo.processInfo.environment["MONEY_TRACE"] != nil {
            let b = dets.filter { $0.cls == 0 && $0.conf >= c.billConf }
            FileHandle.standardError.write("MONEY_TRACE raw=\(raw.count) nms=\(dets.count) bills>=conf=\(b.count) kept=\(bills(dets, c).count) found=\(found.count) confs=\(b.map { String(format: "%.2f", $0.conf) })\n".data(using: .utf8)!)
        }
        return found
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


/// The money models' own small download (8.4 MB), published beside the vision model packs at
/// https://ineedhemp.com/models/rtcam/money/money-v3/ with its own `money-manifest.json` (name, size, sha256 per
/// file). The vision packs and their manifests are untouched, so apps that don't know about money never see it.
/// It is fetched only after a tap (a vision model download the user started; review.md: downloads only after a tap).
enum MoneyPack {
    static let base = URL(string: "https://ineedhemp.com/models/rtcam/money/money-v3/")!
    static let manifestName = "money-manifest.json"
    struct Manifest: Codable { struct File: Codable { let name: String; let size: Int64; let sha256: String }; let version: String; let files: [File] }
    enum PackError: Error { case badManifest, badFile(String), http(Int, String) }

    static var root: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MoneyModels", isDirectory: true)
    }
    /// The installed folder, when its manifest says every file is there at its size.
    static var installedFolder: URL? {
        guard let dir = root?.appendingPathComponent(MoneyDetector.modelVersion, isDirectory: true) else { return nil }
        return isComplete(dir) ? dir : nil
    }
    static func isComplete(_ dir: URL) -> Bool {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(manifestName)),
              let m = try? JSONDecoder().decode(Manifest.self, from: d), m.version == MoneyDetector.modelVersion else { return false }
        return m.files.allSatisfy { f in
            (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(f.name).path)[.size] as? Int64) == f.size
        }
    }

    /// Downloads every file into a staging folder, checks each one's size and SHA-256, then moves the folder into
    /// place in one step. Nothing is half-installed: a bad file throws and the staging folder is removed.
    @discardableResult
    static func install(from base: URL = base, into rootDir: URL? = root, session: URLSession = .shared) async throws -> URL {
        guard let rootDir else { throw PackError.badManifest }
        let fm = FileManager.default
        let final = rootDir.appendingPathComponent(MoneyDetector.modelVersion, isDirectory: true)
        if isComplete(final) { return final }
        let staging = rootDir.appendingPathComponent(MoneyDetector.modelVersion + ".partial", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let (md, mr) = try await session.data(from: base.appendingPathComponent(manifestName))
            if let h = mr as? HTTPURLResponse, !(200 ..< 300).contains(h.statusCode) { throw PackError.http(h.statusCode, manifestName) }
            guard let m = try? JSONDecoder().decode(Manifest.self, from: md), m.version == MoneyDetector.modelVersion, !m.files.isEmpty
            else { throw PackError.badManifest }
            for f in m.files {
                guard !f.name.contains(".."), !f.name.hasPrefix("/") else { throw PackError.badFile(f.name) }
                let (d, r) = try await session.data(from: base.appendingPathComponent(f.name))
                if let h = r as? HTTPURLResponse, !(200 ..< 300).contains(h.statusCode) { throw PackError.http(h.statusCode, f.name) }
                guard Int64(d.count) == f.size, sha256Hex(d) == f.sha256 else { throw PackError.badFile(f.name) }
                let dst = staging.appendingPathComponent(f.name)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try d.write(to: dst, options: .atomic)
            }
            try md.write(to: staging.appendingPathComponent(manifestName), options: .atomic)
            try? fm.removeItem(at: final)
            try fm.moveItem(at: staging, to: final)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        MoneyDetector.reload()
        return final
    }

    static func sha256Hex(_ d: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }
}
