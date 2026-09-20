#if HELP_ME_AIM_SHOT_LOG
import AVFoundation
import CoreImage
import CoreML
import SwiftUI
import UIKit

// MARK: - Room Scan (DEV-INSTALL TEST AID ONLY)
//
// Compiled in only with HELP_ME_AIM_SHOT_LOG on the xcodebuild command line,
// and started only by the launch argument `-roomScan <seconds>`, so nothing
// here can reach TestFlight or the App Store. Matt's census of what YOLOE and
// the 601 model actually see in a real room (Help Me Aim: a bunch of keys was
// not found as "key"). Every 0.5 s: the frame as JPEG plus every detection of
// both models at a 0.10 floor; at the end a per-model summary.

enum RoomScan {
    /// Seconds requested with `-roomScan N`, or 0.
    static var requestedSeconds: Int { UserDefaults.standard.integer(forKey: "roomScan") }
    static let floor: Float = 0.10
    static let interval: TimeInterval = 0.5
    static let jpegLongSide: CGFloat = 1600

    struct Detection: Codable {
        var model: String
        var cls: String
        var conf: Double
        /// x, y, w, h normalized to the saved frame, top-left origin.
        var box: [Double]

        enum CodingKeys: String, CodingKey { case model, cls = "class", conf, box }
    }

    struct FrameRecord: Codable {
        var index: Int
        var t: Double
        var file: String
        var detections: [Detection]
    }

    struct ClassSummary: Codable {
        var cls: String
        var maxConf: Double
        var frames: Int
        enum CodingKeys: String, CodingKey { case cls = "class", maxConf, frames }
    }

    struct Summary: Codable {
        var seconds: Int
        var frames: Int
        var floor: Double
        var models: [String: [ClassSummary]]
    }
}

/// Runs a letterboxed 640×640 detector and returns every box over the floor,
/// after per-class non-max suppression.
final class RoomScanModel {
    enum Kind { case yoloe, oiv7 }

    let name: String
    private let kind: Kind
    private let model: MLModel
    private let inputName: String
    private let pixelFormat: OSType
    private let classNames: [String]
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var pool: CVPixelBufferPool?

    init?(kind: Kind) {
        self.kind = kind
        let resource: String
        switch kind {
        case .yoloe:
            name = "yoloe11s_pf"; resource = "yoloe11s_pf"
            classNames = AimObjectFinder.loadClassNames()
        case .oiv7:
            name = "yolov8n_oiv7"; resource = "yolov8n_oiv7"
            let text = Bundle.main.path(forResource: "class_names", ofType: "txt")
                .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
            classNames = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard let url = Bundle.main.url(forResource: resource, withExtension: "mlmodelc") else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let model = try? MLModel(contentsOf: url, configuration: config) else { return nil }
        self.model = model
        let input = model.modelDescription.inputDescriptionsByName.first { $0.value.type == .image }
        inputName = input?.key ?? "image"
        pixelFormat = input?.value.imageConstraint?.pixelFormatType ?? kCVPixelFormatType_32BGRA
    }

    func detect(_ image: CIImage) -> [RoomScan.Detection] {
        let w = image.extent.width, h = image.extent.height
        guard w > 0, h > 0, let input = letterbox(image) else { return [] }
        let scale = min(640 / w, 640 / h)
        let padX = (640 - w * scale) / 2, padY = (640 - h * scale) / 2
        guard let features = try? MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: input)]),
              let out = try? model.prediction(from: features) else { return [] }

        var raw: [(cls: Int, conf: Float, box: CGRect)] = []
        func toRect(_ cx: Float, _ cy: Float, _ bw: Float, _ bh: Float) -> CGRect? {
            let x = (CGFloat(cx) - padX) / scale, y = (CGFloat(cy) - padY) / scale
            let ww = CGFloat(bw) / scale, hh = CGFloat(bh) / scale
            let r = CGRect(x: (x - ww / 2) / w, y: (y - hh / 2) / h, width: ww / w, height: hh / h)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            return r.isNull || r.width < 0.005 || r.height < 0.005 ? nil : r
        }

        switch kind {
        case .yoloe:
            guard let conf = out.featureValue(for: "confidence")?.multiArrayValue,
                  let cls = out.featureValue(for: "class_id")?.multiArrayValue,
                  let boxes = out.featureValue(for: "boxes")?.multiArrayValue,
                  boxes.strides.count == 3 else { return [] }
            let n = conf.count
            let rs = boxes.strides[1].intValue, cs = boxes.strides[2].intValue
            let confS = conf.strides.last?.intValue ?? 1, clsS = cls.strides.last?.intValue ?? 1
            for i in 0 ..< n {
                let c = Self.float(conf, i * confS)
                guard c >= RoomScan.floor else { continue }
                let id = cls.dataType == .int32
                    ? Int(cls.dataPointer.assumingMemoryBound(to: Int32.self)[i * clsS])
                    : Int(Self.float(cls, i * clsS))
                let at = i * cs
                if let r = toRect(Self.float(boxes, at), Self.float(boxes, rs + at),
                                  Self.float(boxes, 2 * rs + at), Self.float(boxes, 3 * rs + at)) {
                    raw.append((id, c, r))
                }
            }
        case .oiv7:
            guard let arr = out.featureValue(for: "var_914")?.multiArrayValue
                ?? out.featureNames.compactMap({ out.featureValue(for: $0)?.multiArrayValue }).first,
                  arr.shape.count == 3, arr.strides.count == 3 else { return [] }
            let channels = arr.shape[1].intValue, n = arr.shape[2].intValue
            let rs = arr.strides[1].intValue, cs = arr.strides[2].intValue
            let classes = channels - 4
            for i in 0 ..< n {
                let at = i * cs
                var best: Float = 0
                var bestID = 0
                for k in 0 ..< classes {
                    let v = Self.float(arr, (4 + k) * rs + at)
                    if v > best { best = v; bestID = k }
                }
                guard best >= RoomScan.floor else { continue }
                if let r = toRect(Self.float(arr, at), Self.float(arr, rs + at),
                                  Self.float(arr, 2 * rs + at), Self.float(arr, 3 * rs + at)) {
                    raw.append((bestID, best, r))
                }
            }
        }

        // Per-class greedy NMS, at most 100 boxes a frame.
        raw.sort { $0.conf > $1.conf }
        var kept: [(cls: Int, conf: Float, box: CGRect)] = []
        for d in raw {
            if kept.count >= 100 { break }
            let clash = kept.contains { $0.cls == d.cls && Self.iou($0.box, d.box) > 0.5 }
            if !clash { kept.append(d) }
        }
        return kept.map { d in
            RoomScan.Detection(
                model: name,
                cls: d.cls < classNames.count ? classNames[d.cls] : "class \(d.cls)",
                conf: (Double(d.conf) * 1000).rounded() / 1000,
                box: [d.box.minX, d.box.minY, d.box.width, d.box.height].map { (Double($0) * 1000).rounded() / 1000 })
        }
    }

    private static func float(_ a: MLMultiArray, _ i: Int) -> Float {
        switch a.dataType {
        case .float16: Float(a.dataPointer.assumingMemoryBound(to: Float16.self)[i])
        case .double: Float(a.dataPointer.assumingMemoryBound(to: Double.self)[i])
        case .int32: Float(a.dataPointer.assumingMemoryBound(to: Int32.self)[i])
        default: a.dataPointer.assumingMemoryBound(to: Float.self)[i]
        }
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }

    private func letterbox(_ source: CIImage) -> CVPixelBuffer? {
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: 640,
                kCVPixelBufferHeightKey as String: 640,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }
        let w = source.extent.width, h = source.extent.height
        let scale = min(640 / w, 640 / h)
        let canvas = CGRect(x: 0, y: 0, width: 640, height: 640)
        let gray = CIImage(color: CIColor(red: 114 / 255, green: 114 / 255, blue: 114 / 255)).cropped(to: canvas)
        let image = source
            .transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (640 - w * scale) / 2, y: (640 - h * scale) / 2))
            .composited(over: gray)
        context.render(image, to: out, bounds: canvas, colorSpace: CGColorSpaceCreateDeviceRGB())
        return out
    }
}

/// Collects frames on the camera's video queue.
final class RoomScanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var startedAt: Date?
    private var lastAt = Date.distantPast
    private var done = false
    private var index = 0
    private var records: [RoomScan.FrameRecord] = []
    private let seconds: Int
    private let dir: URL
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var models: [RoomScanModel] = []
    var onFinish: (() -> Void)?

    init(seconds: Int) {
        self.seconds = seconds
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("RoomScan/\(f.string(from: Date()))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func loadModels() {
        let loaded = [RoomScanModel(kind: .yoloe), RoomScanModel(kind: .oiv7)].compactMap { $0 }
        lock.lock(); models = loaded; lock.unlock()
    }

    func offer(_ buffer: CVPixelBuffer) {
        let now = Date()
        lock.lock()
        guard !done, !models.isEmpty, now.timeIntervalSince(lastAt) >= RoomScan.interval else { lock.unlock(); return }
        if startedAt == nil { startedAt = now }
        let t = now.timeIntervalSince(startedAt!)
        if t >= Double(seconds) {
            done = true
            lock.unlock()
            finish()
            return
        }
        lastAt = now
        let i = index
        index += 1
        let models = models
        lock.unlock()

        autoreleasepool {
            let image = CIImage(cvPixelBuffer: buffer)
            let long = max(image.extent.width, image.extent.height)
            let s = min(1, RoomScan.jpegLongSide / long)
            let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let file = String(format: "frame-%03d.jpg", i)
            if let jpeg = context.jpegRepresentation(of: small, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                     options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85]) {
                try? jpeg.write(to: dir.appendingPathComponent(file))
            }
            var dets: [RoomScan.Detection] = []
            for m in models { dets += m.detect(image) }
            let rec = RoomScan.FrameRecord(index: i, t: (t * 100).rounded() / 100, file: file, detections: dets)
            if let json = try? JSONEncoder().encode(rec) {
                try? json.write(to: dir.appendingPathComponent(String(format: "frame-%03d.json", i)))
            }
            lock.lock(); records.append(rec); lock.unlock()
        }
    }

    private func finish() {
        lock.lock()
        let all = records
        let names = models.map(\.name)
        lock.unlock()
        var per: [String: [RoomScan.ClassSummary]] = [:]
        for name in names {
            var maxConf: [String: Double] = [:]
            var frames: [String: Set<Int>] = [:]
            for r in all {
                for d in r.detections where d.model == name {
                    maxConf[d.cls] = max(maxConf[d.cls] ?? 0, d.conf)
                    frames[d.cls, default: []].insert(r.index)
                }
            }
            per[name] = maxConf.map { RoomScan.ClassSummary(cls: $0.key, maxConf: $0.value, frames: frames[$0.key]?.count ?? 0) }
                .sorted { $0.maxConf > $1.maxConf }
        }
        let summary = RoomScan.Summary(seconds: seconds, frames: all.count, floor: Double(RoomScan.floor), models: per)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let json = try? enc.encode(summary) {
            try? json.write(to: dir.appendingPathComponent("summary.json"))
        }
        DispatchQueue.main.async { self.onFinish?() }
    }
}

private struct RoomScanCamera: UIViewRepresentable {
    let recorder: RoomScanRecorder

    func makeUIView(context _: Context) -> AimCameraView {
        let view = AimCameraView()
        view.onFrame = { [recorder] buffer, _ in recorder.offer(buffer) }
        view.start(position: .back)
        return view
    }

    func updateUIView(_: AimCameraView, context _: Context) {}

    static func dismantleUIView(_ view: AimCameraView, coordinator _: ()) {
        view.stop()
    }
}

struct RoomScanView: View {
    @State private var recorder = RoomScanRecorder(seconds: max(5, RoomScan.requestedSeconds))
    @State private var status = "Loading models"
    @State private var started = false
    @State private var synth = AVSpeechSynthesizer()

    var body: some View {
        ZStack(alignment: .bottom) {
            if started {
                RoomScanCamera(recorder: recorder).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            Text(status)
                .font(.title3.weight(.semibold))
                .foregroundColor(.white)
                .padding(12)
                .background(Color.black.opacity(0.6))
                .cornerRadius(12)
                .padding(.bottom, 30)
        }
        .onAppear {
            let rec = recorder
            rec.onFinish = {
                status = "Scan done"
                say("scan done")
            }
            DispatchQueue.global(qos: .userInitiated).async {
                rec.loadModels()
                DispatchQueue.main.async {
                    status = "Room scan: move the phone slowly around the room"
                    say("room scan, move the phone slowly around the room")
                    started = true
                }
            }
        }
    }

    private func say(_ text: String) {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audio.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.52
        synth.speak(u)
    }
}
#endif
