// The camera for Live Cam (ported from Moonstone's LiveCamera, 2026-11-04): its own capture session, upright frames, a flip button, and a tiny gray
// thumbnail for the cheap "did the view change?" check. Nothing is saved or sent.
import AVFoundation
import CoreImage
import UIKit

final class LiveCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "live.camera", qos: .userInitiated)
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var device: AVCaptureDevice?
    /// The device zoom factor that means "1x" on screen (2 on a virtual camera whose 1.0 is the ultra wide).
    private var oneX: CGFloat = 1
    private var zoomShown: CGFloat = 1

    /// The device zoom factor that reads as "1x".
    static func oneX(hasUltraWide: Bool, firstSwitchOver: CGFloat?) -> CGFloat { hasUltraWide ? (firstSwitchOver ?? 1) : 1 }
    /// The widest zoom this camera has, as people read it (0.5 on a phone with an ultra wide, else 1).
    var minZoom: CGFloat { lock.lock(); defer { lock.unlock() }; return minShown }
    private var minShown: CGFloat = 1
    /// Zoom as people read it (0.5x ... 1x ... 25x).
    var zoom: CGFloat { lock.lock(); defer { lock.unlock() }; return zoomShown }

    /// Set the zoom as people read it; clamped to what this camera can do.
    func setZoom(_ shown: CGFloat) {
        queue.async { [self] in
            guard let d = device else { return }
            let f = min(max(shown * oneX, d.minAvailableVideoZoomFactor), d.maxAvailableVideoZoomFactor)
            guard (try? d.lockForConfiguration()) != nil else { return }
            d.videoZoomFactor = f
            d.unlockForConfiguration()
            lock.lock(); zoomShown = f / oneX; lock.unlock()
        }
    }
    private var latestAt = Date.distantPast

    // MARK: Flashlight (Matt 11/6: "Live cam needs to have a flashlight")

    /// The back camera has a torch on this phone.
    static let torchAvailable: Bool = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)?.hasTorch ?? false
    /// The person wants the light on (kept across the camera's own reconfigure; back camera only).
    private var torchWanted = false
    /// Whether the light is really on, from the camera queue each time it changes (review 11/6: the button showed On
    /// when the torch had failed). The owner publishes it.
    var onTorch: ((Bool) -> Void)?
    /// Tests: stands in for the real torch (returns whether it is on afterwards).
    var torchSetter: ((Bool) -> Bool)?

    /// Light on or off. "On" from the selfie side flips to the back camera first, decided on the camera queue
    /// (so a flip still pending can't make it guess wrong).
    func setTorch(_ on: Bool) {
        queue.async { [self] in
            if on, position == .front, stillFrame == nil {
                // Review 11/6 round 3: wanted first, so the flip's own reconfigure lights it (and reports it lit)
                // instead of reporting "off" and the app saying the flashlight isn't working.
                lock.lock(); torchWanted = true; lock.unlock()
                flipNow()
            }
            lock.lock(); torchWanted = on && (position == .back || stillFrame != nil); lock.unlock()
            applyTorch()
        }
    }

    /// Call on `queue`: makes the torch match torchWanted and reports what it really is.
    private func applyTorch() {
        lock.lock(); let on = torchWanted; lock.unlock()
        let lit: Bool
        if let torchSetter {
            lit = torchSetter(on)
        } else if let d = device, d.hasTorch, (try? d.lockForConfiguration()) != nil {
            if on, d.isTorchModeSupported(.on) { try? d.setTorchModeOn(level: 1.0) } else if d.torchMode != .off { d.torchMode = .off }
            lit = d.torchMode == .on
            d.unlockForConfiguration()
        } else {
            lit = stillFrame != nil && on   // the harness has no camera: the light is what was asked for
        }
        onTorch?(lit)
    }

    /// The camera was interrupted: the light is off now (it comes back when the camera restarts).
    func interruptionBegan() { queue.async { [self] in onTorch?(false) } }
    /// After a restart: the light as the person left it.
    func reapplyTorch() { queue.async { [self] in applyTorch() } }
    /// A call wants the camera running (stop() clears it, so an interruption ending never restarts a closed call).
    private var wanted = false
    private var watching = false
    /// 11/1 Matt, driving: "it keeps repeating itself... not seeing anything new". iOS can pause the camera mid-call
    /// (heat with the model on the GPU, CarPlay or another app taking it, an audio route change) and the last frame
    /// stayed in `latest` forever, so every question got the same old picture and the same answer. A frame older
    /// than this is never handed out; the camera is restarted instead.
    static let maxFrameAge: TimeInterval = 1.5
    /// The last camera used, remembered between calls.
    private var position: AVCaptureDevice.Position =
        UserDefaults.standard.bool(forKey: "liveCamFrontCamera") ? .front : .back
    var isFront: Bool { lock.lock(); defer { lock.unlock() }; return front }
    private var front = UserDefaults.standard.bool(forKey: "liveCamFrontCamera")
    /// Test aid: frames from a still photo instead of the camera.
    var stillFrame: CGImage?

    static var allowed: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    static func requestAccess() async -> Bool {
        if allowed { return true }
        return await AVCaptureDevice.requestAccess(for: .video)
    }

    func start() {
        guard stillFrame == nil else { return }
        watchInterruptions()
        queue.async { [self] in
            wanted = true
            if session.inputs.isEmpty { configure() }
            if !session.isRunning { session.startRunning() }
        }
    }

    /// A visit wants the camera on (read off the camera queue, so a pending start or stop has landed).
    var isWanted: Bool { queue.sync { wanted } }

    func stop() {
        lock.lock(); torchWanted = false; lock.unlock()
        queue.async { [self] in
            wanted = false
            // Again here: a torch tap queued before Back must not leave the light on (review 11/6 round 3).
            lock.lock(); torchWanted = false; lock.unlock()
            applyTorch()   // the light goes off with the camera
            if session.isRunning { session.stopRunning() }
            lock.lock(); latest = nil; latestAt = .distantPast; lock.unlock()
        }
    }

    /// Bring the camera back after iOS paused or broke it, as long as a call still wants it.
    func restart(_ why: String) {
        queue.async { [self] in
            guard wanted else { return }
            onEvent?(["event": "camera_restart", "why": why])
            if session.inputs.isEmpty { configure() }
            if session.isRunning { session.stopRunning() }
            session.startRunning()
            applyTorch()   // review 11/6: the light comes back after an interruption, and the button says so
        }
    }

    /// Camera events for the call log (interrupted, restarted, stale frame).
    var onEvent: (([String: Any]) -> Void)?

    private func watchInterruptions() {
        guard !watching else { return }
        watching = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] n in
            let r = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue ?? -1
            self?.onEvent?(["event": "camera_interrupted", "reason": r])
            self?.interruptionBegan()
        }
        nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.restart("interruption ended")
        }
        nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
            let e = (n.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? 0
            self?.onEvent?(["event": "camera_error", "code": e])
            self?.restart("runtime error")
        }
    }

    func flip() {
        guard stillFrame == nil else { return }
        queue.async { [self] in flipNow() }
    }

    /// Call on `queue`.
    private func flipNow() {
        if position == .back { lock.lock(); torchWanted = false; lock.unlock(); applyTorch() }   // no light on the selfie side
        position = position == .back ? .front : .back
        lock.lock(); front = position == .front; lock.unlock()
        UserDefaults.standard.set(position == .front, forKey: "liveCamFrontCamera")
        configure()
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.automaticallyConfiguresApplicationAudioSession = false   // never take over the call's audio
        session.sessionPreset = .hd1280x720
        session.inputs.forEach { session.removeInput($0) }
        // 11/2 Matt: two-finger zoom on the back camera, the whole range. The back uses the phone's virtual multi-lens
        // camera (0.5x ultra wide up to the max digital zoom), so iOS switches lenses on its own like the Camera app.
        let back: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let cam = position == .back ? back.lazy.compactMap { AVCaptureDevice.default($0, for: .video, position: .back) }.first
                                    : AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        guard let cam, let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) else { return }
        session.addInput(input)
        device = cam
        // Open at the main lens (1x), not the ultra wide, when the virtual camera starts below it.
        // Review 11/6: only a camera with an ultra wide starts below 1x; a wide + tele pair's first switch-over is the
        // tele (2x), and taking it as "1x" showed a 0.5 pill that was really the main lens.
        let hasUltraWide = cam.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let one = Self.oneX(hasUltraWide: hasUltraWide,
                            firstSwitchOver: cam.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) })
        oneX = one
        if (try? cam.lockForConfiguration()) != nil { cam.videoZoomFactor = one; cam.unlockForConfiguration() }
        lock.lock(); zoomShown = 1; minShown = hasUltraWide ? cam.minAvailableVideoZoomFactor / one : 1; lock.unlock()
        if position == .back { applyTorch() }   // a reconfigure (restart, flip back) keeps the light as it was
        if session.outputs.isEmpty {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        if let c = output.connection(with: .video) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }   // portrait, upright
            if c.isVideoMirroringSupported { c.isVideoMirrored = position == .front }
        }
    }

    func captureOutput(_: AVCaptureOutput, didOutput sb: CMSampleBuffer, from _: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lock.lock(); let before = latestAt; latest = pb; latestAt = Date(); lock.unlock()
        #if DEBUG
        // -liveCamHitch: camera frames more than 80 ms apart (the picture would stall).
        if LiveCamTest.hitch, before != .distantPast {
            let ms = Date().timeIntervalSince(before) * 1000
            if ms > 80 { LiveCamTest.log(["event": "cam_gap", "ms": Int(ms)]) }
        }
        #endif
    }

    /// The frame on screen right now, copied on the CPU (no GPU work, so the model and the preview
    /// never queue behind it). Call off the main thread.
    func current() -> CGImage? {
        if let stillFrame { return stillFrame }
        lock.lock(); let pb = latest, age = Date().timeIntervalSince(latestAt); lock.unlock()
        guard let pb else { return nil }
        guard age <= Self.maxFrameAge else {   // the camera stopped: never describe an old picture as "now"
            onEvent?(["event": "camera_stale", "age_s": (age * 10).rounded() / 10])
            restart("stale frame")
            return nil
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        return ctx.makeImage()
    }

    /// 16 x 16 gray thumbnail (256 bytes) for the change check.
    static func thumb(_ image: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 256)
        px.withUnsafeMutableBytes { buf in
            guard let c = CGContext(data: buf.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            c.interpolationQuality = .low
            c.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return px
    }
}
