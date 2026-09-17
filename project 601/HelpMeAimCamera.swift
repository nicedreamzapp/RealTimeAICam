import AVFoundation
import CoreImage
import CoreML
import UIKit
import Vision

// MARK: - Help Me Aim: camera and detectors
//
// Help Me Aim has its own capture session on purpose: the other screens'
// camera (CameraPreviewView) and the 601-class detector stay exactly as they
// are. Asked for by Dennis Long (Pixel Guided Frame) and the AppleVis testers.

/// Full-screen preview with its own session, a still-photo output, and a
/// frame callback. Video frames arrive already turned to portrait (and
/// mirrored for the front camera, like a selfie preview), so a box found in
/// them lines up with what the person would see on screen.
final class AimCameraView: UIView {
    /// Called on the video queue with a portrait frame and how many extra
    /// clockwise quarter turns the phone is held at right now.
    var onFrame: ((CVPixelBuffer, Int) -> Void)?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "aim.camera.session")
    private let videoQueue = DispatchQueue(label: "aim.camera.video", qos: .userInitiated)
    private var device: AVCaptureDevice?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var position: AVCaptureDevice.Position = .back
    private var configured = false

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    private var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    /// Same layer, captured on the main thread so the session queue never
    /// asks UIView for it (Main Thread Checker, first live run).
    private var cachedPreviewLayer: AVCaptureVideoPreviewLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        // Aspect-fit: what is on screen is exactly what is being analysed.
        previewLayer.videoGravity = .resizeAspect
        previewLayer.session = session
        cachedPreviewLayer = previewLayer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var hasTorch: Bool { device?.hasTorch ?? false }

    /// Configure (or switch) the camera and start it.
    func start(position newPosition: AVCaptureDevice.Position) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !configured || newPosition != position {
                position = newPosition
                configure()
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        setTorch(false)
        sessionQueue.async { [weak self] in
            guard let self, session.isRunning else { return }
            session.stopRunning()
        }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Never let the camera take over the app's audio route (the spoken
        // steering would drop to the earpiece), same rule as CameraPreviewView.
        session.automaticallyConfiguresApplicationAudioSession = false
        // 4:3 like the photo, so "framed" in the preview means framed in the picture.
        session.sessionPreset = .photo

        session.inputs.forEach { session.removeInput($0) }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input)
        else { return }
        session.addInput(input)
        device = camera
        rotation = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)

        if let _ = try? camera.lockForConfiguration() {
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
            camera.unlockForConfiguration()
        }

        if !configured {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                photoOutput.maxPhotoQualityPrioritization = .quality
            }
            configured = true
        }

        if let connection = videoOutput.connection(with: .video) {
            // 90° = portrait for both cameras. The UI is portrait-only on iPhone.
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = position == .front
            }
        }
        DispatchQueue.main.async { [weak self] in
            if let preview = self?.cachedPreviewLayer?.connection, preview.isVideoRotationAngleSupported(90) {
                preview.videoRotationAngle = 90
            }
        }
        // 12 MP, not 48: a burst of five 48 MP frames is slow and huge, and
        // 12 MP leaves plenty to crop from.
        let sizes = camera.activeFormat.supportedMaxPhotoDimensions.filter { $0.width > 0 && $0.height > 0 }
        if let pick = sizes.filter({ max($0.width, $0.height) <= 4032 }).max(by: { $0.width < $1.width }) ?? sizes.first {
            photoOutput.maxPhotoDimensions = pick
        }
    }

    func setTorch(_ on: Bool) {
        guard let device, device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
        if on {
            try? device.setTorchModeOn(level: 1.0)
        } else {
            device.torchMode = .off
        }
        device.unlockForConfiguration()
    }

    /// A short burst of JPEG stills, `interval` apart, upright the way the
    /// phone is held (EXIF orientation). `completion` runs on the main queue
    /// with the frames that came back, in order (empty on failure).
    /// Round 2 of Help Me Aim: shoot a few and keep the best-framed one.
    func captureBurst(count: Int, interval: TimeInterval, completion: @escaping ([Data]) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, session.isRunning,
                  let connection = photoOutput.connection(with: .video), connection.isActive
            else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            if let angle = rotation?.videoRotationAngleForHorizonLevelCapture,
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            let group = DispatchGroup()
            let lock = NSLock()
            var results = [Data?](repeating: nil, count: count)
            var delegates: [PhotoDelegate] = []
            for i in 0 ..< count {
                group.enter()
                sessionQueue.asyncAfter(deadline: .now() + interval * Double(i)) { [weak self] in
                    guard let self, session.isRunning else { group.leave(); return }
                    let settings: AVCapturePhotoSettings
                    if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                        settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                    } else {
                        settings = AVCapturePhotoSettings()
                    }
                    settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
                    // Speed: the frames are taken close together on purpose.
                    settings.photoQualityPrioritization = .speed
                    if photoOutput.supportedFlashModes.contains(.off) { settings.flashMode = .off }
                    let delegate = PhotoDelegate { data in
                        lock.lock(); results[i] = data; lock.unlock()
                        group.leave()
                    }
                    delegates.append(delegate)
                    photoOutput.capturePhoto(with: settings, delegate: delegate)
                }
            }
            group.notify(queue: .main) {
                _ = delegates.count // keep the delegates alive until every frame is back
                completion(results.compactMap { $0 })
            }
        }
    }

    private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
        let done: (Data?) -> Void
        init(done: @escaping (Data?) -> Void) { self.done = done }
        func photoOutput(_: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            done(error == nil ? photo.fileDataRepresentation() : nil)
        }
    }
}

extension AimCameraView: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Landscape steering is only worked out for the back camera; the
        // front (selfie) camera is treated as held upright.
        var turns = 0
        if position == .back, let angle = rotation?.videoRotationAngleForHorizonLevelCapture {
            turns = AimSteering.quarterTurns(levelAngle: angle)
        }
        onFrame?(buffer, turns)
    }
}

// MARK: - YOLOE (Something Else, and the page backup)

/// YOLOE-11s prompt-free, 4,585 classes, decode baked into the graph
/// (conversion recipe: Vision Builder scripts/convert_yoloe.py). Loaded only
/// while Help Me Aim is open and filtered to the ONE thing asked for, at the
/// 0.35 floor Vision Builder uses (the July test with 601's ~0.05 floors
/// over-detected badly).
final class AimObjectFinder {
    static let modelName = "yoloe11s_pf"
    static let confidenceFloor: Float = 0.35
    static let inputSize = 640

    private let model: MLModel
    private let inputName: String
    private let pixelFormat: OSType
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var pool: CVPixelBufferPool?

    static func loadClassNames() -> [String] {
        guard let url = Bundle.main.url(forResource: "yoloe_classes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return names
    }

    init?() {
        guard let url = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let model = try? MLModel(contentsOf: url, configuration: config) else { return nil }
        self.model = model
        let input = model.modelDescription.inputDescriptionsByName.first { $0.value.type == .image }
        inputName = input?.key ?? "image"
        pixelFormat = input?.value.imageConstraint?.pixelFormatType ?? kCVPixelFormatType_32BGRA
    }

    /// Best box (top-left origin, normalized to `buffer`) among the wanted
    /// classes, or nil.
    func find(in buffer: CVPixelBuffer, classIDs: Set<Int32>) -> (box: CGRect, score: Float)? {
        find(in: CIImage(cvPixelBuffer: buffer), classIDs: classIDs)
    }

    func find(in image: CIImage, classIDs: Set<Int32>) -> (box: CGRect, score: Float)? {
        guard !classIDs.isEmpty else { return nil }
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard w > 0, h > 0, let input = letterbox(image, width: w, height: h) else { return nil }
        let side = Float(Self.inputSize)
        let scale = min(side / Float(w), side / Float(h))
        let padX = (side - Float(w) * scale) / 2
        let padY = (side - Float(h) * scale) / 2

        guard let features = try? MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: input)]),
              let out = try? model.prediction(from: features),
              let conf = out.featureValue(for: "confidence")?.multiArrayValue,
              let cls = out.featureValue(for: "class_id")?.multiArrayValue,
              let boxes = out.featureValue(for: "boxes")?.multiArrayValue
        else { return nil }

        let n = conf.count
        guard cls.count == n, boxes.count == 4 * n, boxes.shape.count == 3, boxes.strides.count == 3 else { return nil }
        // The arrays are NOT laid out contiguously: on device the boxes come
        // back with strides [33664, 8416, 1] (rows padded to 8416), so every
        // read goes through the strides. Reading row c at c * 8400 + i took
        // y/width/height from a neighbouring anchor (boxes 2-4x too tall,
        // found in the first live run 2026-09-16).
        let rowStride = boxes.strides[1].intValue, colStride = boxes.strides[2].intValue
        let lastStride = { (a: MLMultiArray) in a.strides.last?.intValue ?? 1 }
        let confStride = lastStride(conf), clsStride = lastStride(cls)
        func value(_ a: MLMultiArray, _ i: Int) -> Float {
            switch a.dataType {
            case .float16: Float(a.dataPointer.assumingMemoryBound(to: Float16.self)[i])
            case .double: Float(a.dataPointer.assumingMemoryBound(to: Double.self)[i])
            default: a.dataPointer.assumingMemoryBound(to: Float.self)[i]
            }
        }
        func classID(_ i: Int) -> Int32 {
            switch cls.dataType {
            case .int32: cls.dataPointer.assumingMemoryBound(to: Int32.self)[i * clsStride]
            default: Int32(value(cls, i * clsStride))
            }
        }

        var best: (box: CGRect, score: Float)?
        for i in 0 ..< n where classIDs.contains(classID(i)) {
            let score = value(conf, i * confStride)
            guard score >= Self.confidenceFloor, score > (best?.score ?? 0) else { continue }
            let at = i * colStride
            let cx = (value(boxes, at) - padX) / scale
            let cy = (value(boxes, rowStride + at) - padY) / scale
            let bw = value(boxes, 2 * rowStride + at) / scale
            let bh = value(boxes, 3 * rowStride + at) / scale
            var rect = CGRect(
                x: CGFloat((cx - bw / 2) / Float(w)), y: CGFloat((cy - bh / 2) / Float(h)),
                width: CGFloat(bw / Float(w)), height: CGFloat(bh / Float(h)))
            rect = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !rect.isNull, rect.width > 0.01, rect.height > 0.01 else { continue }
            best = (rect, score)
        }
        return best
    }

    private func letterbox(_ source: CIImage, width w: Int, height h: Int) -> CVPixelBuffer? {
        let side = Self.inputSize
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: side,
                kCVPixelBufferHeightKey as String: side,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }

        let scale = min(CGFloat(side) / CGFloat(w), CGFloat(side) / CGFloat(h))
        let padX = (CGFloat(side) - CGFloat(w) * scale) / 2
        let padY = (CGFloat(side) - CGFloat(h) * scale) / 2
        let canvas = CGRect(x: 0, y: 0, width: side, height: side)
        let gray = CIImage(color: CIColor(red: 114 / 255, green: 114 / 255, blue: 114 / 255)).cropped(to: canvas)
        let image = source
            .transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: padX, y: padY))
            .composited(over: gray)
        context.render(image, to: out, bounds: canvas, colorSpace: CGColorSpaceCreateDeviceRGB())
        return out
    }
}

// MARK: - Frame analysis

/// One analysed frame: the subject's box in the frame the person is holding
/// (top-left origin), and how many faces it covers.
struct AimObservation {
    var box: CGRect?
    var count: Int
}

/// Runs the right detector for the subject on the camera's video queue, a
/// few times a second, and reports on the main queue.
final class AimFrameAnalyzer: @unchecked Sendable {
    enum Kind { case face, page, object }

    var onObservation: ((AimObservation) -> Void)?

    private let lock = NSLock()
    private var kind: Kind?
    private var classIDs: Set<Int32> = []
    private var finder: AimObjectFinder?
    private var paused = true
    private var lastRun = Date.distantPast
    private let interval: TimeInterval = 0.12

    /// The class names YOLOE uses for a page or a picture, as a backup to
    /// Apple's rectangle finder (which needs all four corners in view).
    static let pageClassNames = [
        "document", "paper", "picture frame", "photo frame", "poster", "poster page",
        "oil painting", "watercolor painting", "picture", "photo", "letter", "envelope",
        "receipt", "menu", "book",
    ]

    /// Point the analyser at a subject. `finder` is nil for faces.
    func configure(kind: Kind, classIDs: Set<Int32>, finder: AimObjectFinder?) {
        lock.lock()
        self.kind = kind
        self.classIDs = classIDs
        self.finder = finder
        lock.unlock()
    }

    /// What the analyser is currently looking for (for the burst pass).
    func snapshot() -> (kind: Kind, ids: Set<Int32>, finder: AimObjectFinder?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let kind else { return nil }
        return (kind, classIDs, finder)
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    /// Drop the model (leaving the screen).
    func unload() {
        lock.lock()
        kind = nil
        finder = nil
        classIDs = []
        paused = true
        lock.unlock()
    }

    func offer(_ buffer: CVPixelBuffer, quarterTurns: Int) {
        let now = Date()
        lock.lock()
        guard !paused, let kind, now.timeIntervalSince(lastRun) >= interval else {
            lock.unlock()
            return
        }
        lastRun = now
        let ids = classIDs
        let finder = finder
        lock.unlock()

        let observation: AimObservation = autoreleasepool {
            var result: AimObservation
            result = Self.detect(
                kind: kind,
                handler: VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]),
                image: CIImage(cvPixelBuffer: buffer), finder: finder, ids: ids)
            if let box = result.box, quarterTurns != 0 {
                result.box = AimSteering.rotateClockwise(box, quarterTurns: quarterTurns)
            }
            return result
        }

        lock.lock()
        let stillWanted = !paused && self.kind == kind
        lock.unlock()
        guard stillWanted else { return }
        let deliver = onObservation
        DispatchQueue.main.async { deliver?(observation) }
    }

    /// Vision's box has its origin at the bottom-left; ours is top-left.
    static func topLeft(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    /// One detection pass on an upright image (a live frame or a burst still).
    static func detect(kind: Kind, handler: VNImageRequestHandler, image: CIImage,
                       finder: AimObjectFinder?, ids: Set<Int32>) -> AimObservation {
        switch kind {
        case .face: return faces(handler)
        case .page: return page(handler, image: image, finder: finder, ids: ids)
        case .object:
            let found = finder?.find(in: image, classIDs: ids)
            return AimObservation(box: found?.box, count: found == nil ? 0 : 1)
        }
    }

    /// Detection plus sharpness on an upright still (burst frame).
    static func analyzeStill(_ cg: CGImage, kind: Kind, finder: AimObjectFinder?, ids: Set<Int32>) -> AimBurst.Frame {
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        let obs = detect(kind: kind, handler: handler, image: CIImage(cgImage: cg), finder: finder, ids: ids)
        let sharp = FrameQualityGate.check(cg, checkDocumentEdges: false).sharpness
        return AimBurst.Frame(box: obs.box, sharpness: sharp)
    }

    private static func faces(_ handler: VNImageRequestHandler) -> AimObservation {
        let request = VNDetectFaceRectanglesRequest()
        try? handler.perform([request])
        // Tiny faces are a poster or a crowd in the distance.
        let faces = (request.results ?? []).map(\.boundingBox).filter { $0.height >= 0.04 }
        guard let first = faces.first else { return AimObservation(box: nil, count: 0) }
        // Two or more faces: frame the whole group (asked for on AppleVis).
        let group = faces.dropFirst().reduce(first) { $0.union($1) }
        return AimObservation(box: topLeft(group), count: faces.count)
    }

    private static func page(_ handler: VNImageRequestHandler, image: CIImage,
                             finder: AimObjectFinder?, ids: Set<Int32>) -> AimObservation {
        let request = VNDetectRectanglesRequest()
        request.minimumSize = 0.15
        request.maximumObservations = 4
        request.minimumConfidence = 0.7
        request.minimumAspectRatio = 0.25
        request.quadratureTolerance = 25
        try? handler.perform([request])
        let rect = (request.results ?? [])
            .map { topLeft($0.boundingBox) }
            .max { $0.width * $0.height < $1.width * $1.height }
        let backup = finder?.find(in: image, classIDs: ids)?.box
        // The rectangle finder is tighter, but misses a page that runs off
        // the edge; the model still sees that one, so take the bigger.
        let best: CGRect? = switch (rect, backup) {
        case let (r?, b?): r.width * r.height >= b.width * b.height ? r : b
        case let (r?, nil): r
        case let (nil, b?): b
        default: nil
        }
        return AimObservation(box: best, count: best == nil ? 0 : 1)
    }
}
