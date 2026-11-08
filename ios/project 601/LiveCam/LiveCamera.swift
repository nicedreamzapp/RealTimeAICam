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
        queue.async { [self] in
            wanted = false
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
        queue.async { [self] in
            position = position == .back ? .front : .back
            lock.lock(); front = position == .front; lock.unlock()
            UserDefaults.standard.set(position == .front, forKey: "liveCamFrontCamera")
            configure()
        }
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
        let one = cam.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) } ?? 1
        oneX = one
        if (try? cam.lockForConfiguration()) != nil { cam.videoZoomFactor = one; cam.unlockForConfiguration() }
        lock.lock(); zoomShown = 1; lock.unlock()
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
